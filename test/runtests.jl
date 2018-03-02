using BinaryProvider
using BinaryBuilder
using BinaryBuilder: preferred_runner
using ObjectFile
using Base.Test
using SHA
using Compat

# The platform we're running on
const platform = platform_key()

# On windows, the `.exe` extension is very important
const exe_ext = Compat.Sys.iswindows() ? ".exe" : ""

# We are going to build/install libfoo a lot, so here's our function to make sure the
# library is working properly
function check_foo(fooifier_path = "fooifier$(exe_ext)",
                   libfoo_path = "libfoo.$(Libdl.dlext)")
    # We know that foo(a, b) returns 2*a^2 - b
    result = 2*2.2^2 - 1.1

    # Test that we can invoke fooifier
    @test !success(`$fooifier_path`)
    @test success(`$fooifier_path 1.5 2.0`)
    @test parse(Float64,readchomp(`$fooifier_path 2.2 1.1`)) ≈ result

    # Test that we can dlopen() libfoo and invoke it directly
    libfoo = Libdl.dlopen_e(libfoo_path)
    @test libfoo != C_NULL
    foo = Libdl.dlsym_e(libfoo, :foo)
    @test foo != C_NULL
    @test ccall(foo, Cdouble, (Cdouble, Cdouble), 2.2, 1.1) ≈ result
    Libdl.dlclose(libfoo)
end

@testset "File Collection" begin
    temp_prefix() do prefix
        # Create a file and a link, ensure that only the one file is returned by collect_files()
        f = joinpath(prefix, "foo")
        f_link = joinpath(prefix, "foo_link")
        touch(f)
        symlink(f, f_link)

        files = collect_files(prefix)
        @test length(files) == 2
        @test f in files
        @test f_link in files

        collapsed_files = collapse_symlinks(files)
        @test length(collapsed_files) == 1
        @test f in collapsed_files
    end
end

# This file contains tests that require our cross-compilation environment
@testset "Builder Dependency" begin
    temp_prefix() do prefix
        # First, let's create a Dependency that just installs a file
        begin
            ur = preferred_runner()(prefix.path; cwd="/workspace/", platform=platform)

            # Our simple executable file, generated by bash
            test_exe_sandbox_path = joinpath("/workspace/bin", "test_exe")
            test_exe_path = joinpath(bindir(prefix),"test_exe")
            test_exe = ExecutableProduct(test_exe_path, :test_exe)
            results = [test_exe]

            # These commands will be run within the cross-compilation environment
            script = """
            /bin/mkdir -p $(dirname(test_exe_sandbox_path))
            printf '#!/bin/bash\necho test' > $(test_exe_sandbox_path)
            /bin/chmod 775 $(test_exe_sandbox_path)
            """
            dep = Dependency("bash_test", results, script, platform, prefix)

            @test build(ur, dep; verbose=true)
            @test satisfied(dep)
            @test readstring(`$(test_exe_path)`) == "test\n"
        end
    end

    begin
        build_path = tempname()
        mkpath(build_path)
        prefix, ur = BinaryBuilder.setup_workspace(build_path, [], [], [], platform_key())
        cd(joinpath(dirname(@__FILE__),"build_tests","libfoo")) do
            run(`cp $(readdir()) $(joinpath(prefix.path,"..","srcdir"))/`)

            libfoo = LibraryProduct(prefix, "libfoo", :libfoo)
            fooifier = ExecutableProduct(prefix, "fooifier", :fooifier)
            script="""
            /usr/bin/make clean
            /usr/bin/make install
            """
            dep = Dependency("fooifier", [libfoo, fooifier], script, platform, prefix)

            # Build it
            @test build(ur, dep; verbose=true)
            @test satisfied(dep; verbose=true)

            # Test the binaries
            check_foo(locate(fooifier), locate(libfoo))

            # Also test the binaries through `activate()`
            activate(prefix)
            check_foo()
            deactivate(prefix)

            # Test that `collect_files()` works:
            all_files = collect_files(prefix)
            @test locate(libfoo) in all_files
            @test locate(fooifier) in all_files
        end
        rm(build_path, recursive = true)
    end
end

const libfoo_products = prefix->[
    LibraryProduct(prefix, "libfoo", :libfoo)
    ExecutableProduct(prefix, "fooifier", :fooifier)
]
const libfoo_script = """
/usr/bin/make clean
/usr/bin/make install
"""

@testset "Builder Packaging" begin
    # Clear out previous build products
    for f in readdir(".")
        if !endswith(f, ".tar.gz") || !endswith(f, ".tar.gz.256")
            continue
        end
        rm(f; force=true)
    end

    # Gotta set this guy up beforehand
    tarball_path = nothing
    tarball_hash = nothing

    begin
        build_path = tempname()
        mkpath(build_path)
        prefix, ur = BinaryBuilder.setup_workspace(build_path, [], [], [], platform_key())
        cd(joinpath(dirname(@__FILE__),"build_tests","libfoo")) do
            run(`cp $(readdir()) $(joinpath(prefix.path,"..","srcdir"))/`)

            # First, build libfoo
            dep = Dependency("foo", libfoo_products(prefix), libfoo_script, platform, prefix)

            @test build(ur, dep)
        end

        # Next, package it up as a .tar.gz file
        tarball_path, tarball_hash = package(prefix, "./libfoo"; verbose=true)
        @test isfile(tarball_path)

        # Delete the build path
        rm(build_path, recursive = true)
    end

    # Test that we can inspect the contents of the tarball
    contents = list_tarball_files(tarball_path)
    @test "bin/fooifier" in contents
    @test "lib/libfoo.$(Libdl.dlext)" in contents

    # Install it within a new Prefix
    temp_prefix() do prefix
        # Install the thing
        @test install(tarball_path, tarball_hash; prefix=prefix, verbose=true)

        # Ensure we can use it
        fooifier_path = joinpath(bindir(prefix), "fooifier")
        libfoo_path = joinpath(libdir(prefix), "libfoo.$(Libdl.dlext)")
        check_foo(fooifier_path, libfoo_path)
    end

    rm(tarball_path; force=true)
    rm("$(tarball_path).sha256"; force=true)
end

# Testset to make sure we can autobuild from a git repository
@testset "AutoBuild Git-Based" begin
    build_path = tempname()
    git_path = joinpath(build_path,"libfoo.git")
    mkpath(git_path)

    cd(build_path) do
        # Just like we package up libfoo into a tarball above, we'll create a fake
        # git repo for it here, then build from that.
        repo = LibGit2.init(git_path)
        LibGit2.commit(repo, "Initial empty commit")
        libfoo_dir = joinpath(@__DIR__, "build_tests", "libfoo")
        run(`cp -r $(libfoo_dir)/$(readdir(libfoo_dir)) $git_path/`)
        for file in ["fooifier.c", "libfoo.c", "Makefile"]
            LibGit2.add!(repo, file)
        end
        commit = LibGit2.commit(repo, "Add libfoo files")

        # Now build that git repository for Linux x86_64
        sources = [
            git_path =>
            LibGit2.hex(LibGit2.GitHash(commit)),
        ]

        autobuild(
            pwd(),
            "libfoo",
            [Linux(:x86_64, :glibc)],
            sources,
            "cd libfoo\n$libfoo_script",
            libfoo_products
        )

        # Make sure that worked
        @test isfile("products/libfoo.x86_64-linux-gnu.tar.gz")
    end

    rm(build_path; force=true, recursive=true)
end

@testset "Auditor - ISA tests" begin
    begin
        build_path = tempname()
        mkpath(build_path)
        isa_platform = Linux(:x86_64)
        prefix, ur = BinaryBuilder.setup_workspace(build_path, [], [], [], isa_platform)

        main_sse = ExecutableProduct(prefix, "main_sse", :main_sse)
        main_avx = ExecutableProduct(prefix, "main_avx", :main_avx)
        main_avx2 = ExecutableProduct(prefix, "main_avx2", :main_avx2)
        products = [main_sse, main_avx, main_avx2]
        
        cd(joinpath(dirname(@__FILE__),"build_tests","isa_tests")) do
            run(`cp $(readdir()) $(joinpath(prefix.path,"..","srcdir"))/`)

            # Build isa tests
           script="""
            /usr/bin/make clean
            /usr/bin/make install
            """
            dep = Dependency("isa_tests", products, script, isa_platform, prefix)

            # Build it
            @test build(ur, dep; verbose=true)

            # Ensure it's satisfied
            @test satisfied(dep; verbose=true)
        end

        # Next, test isa of these files
        isa_sse = BinaryBuilder.analyze_instruction_set(readmeta(locate(main_sse)); verbose=true)
        @test isa_sse == :core2

        isa_avx = BinaryBuilder.analyze_instruction_set(readmeta(locate(main_avx)); verbose=true)
        @test isa_avx == :sandybridge

        isa_avx2 = BinaryBuilder.analyze_instruction_set(readmeta(locate(main_avx2)); verbose=true)
        @test isa_avx2 == :haswell

        # Delete the build path
        rm(build_path, recursive = true)
    end
end

@testset "GitHub releases build.jl reconstruction" begin
    # Download some random release that is relatively small
    product_hashes = product_hashes_from_github_release("staticfloat/OggBuilder", "v1.3.3-0")

    # Ground truth hashes for each product
    true_product_hashes = Dict(
        "aarch64-linux-gnu" => (
            "Ogg.aarch64-linux-gnu.tar.gz",
            "4150d19fe0dc773ef3917498379a9148cd780d44322fc30e44cf4a241fb8e688"
        ),
        "i686-w64-mingw32" => (
            "Ogg.i686-w64-mingw32.tar.gz",
            "3f9940c1c8614fbb40f35ab28dac9237226e3e7fcfb45d1fe7488e0289284ff8"
        ),
        "powerpc64le-linux-gnu" => (
            "Ogg.powerpc64le-linux-gnu.tar.gz",
            "cf519a13c3b343334aed8771d50b991d7ea00d0bbbd490ee0c8f5ffbd3ba65f4"
        ),
        "x86_64-linux-gnu" => (
            "Ogg.x86_64-linux-gnu.tar.gz",
            "3952d4def1505ad5090622a50662b6e0a38d1977abb7bb61d2483a47b626c807"
        ),
        "x86_64-apple-darwin14" => (
            "Ogg.x86_64-apple-darwin14.tar.gz",
            "e6c0fec453c4f833a0364fbf92a4a6e4bc738aa8de84059e12f1ee40f02dbba1"
        ),
        "x86_64-w64-mingw32" => (
            "Ogg.x86_64-w64-mingw32.tar.gz",
            "a47c33147f7e572f40178d47de54ad3a0a04e6b17a9fe3cf15791ba11203544e"
        ),
        "arm-linux-gnueabihf" => (
            "Ogg.arm-linux-gnueabihf.tar.gz",
            "dcafb1c46b4363f84fc194c28732e3080be82227e36938d883a2d0e381cae20c"
        ),
        "i686-linux-gnu" => (
            "Ogg.i686-linux-gnu.tar.gz",
            "f5227b205ee64e03f7b030af0c6b6eb9ddb6a3175efe1c650935e71dcd3ae658"
        ),
    )

    @test length(product_hashes) == length(true_product_hashes)

    for target in keys(true_product_hashes)
        @test haskey(product_hashes, target)
        product_platform = extract_platform_key(product_hashes[target][1])
        true_product_platform = extract_platform_key(true_product_hashes[target][1])
        @test product_platform == true_product_platform
        @test product_hashes[target][2] == true_product_hashes[target][2]
    end
end

include("wizard.jl")