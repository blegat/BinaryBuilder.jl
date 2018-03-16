import Base: show

"""
    UserNSRunner

A `UserNSRunner` represents an "execution context", an object that bundles all
necessary information to run commands within the container that contains
our crossbuild environment.  Use `run()` to actually run commands within the
`UserNSRunner`, and `runshell()` as a quick way to get an interactive shell
within the crossbuild environment.
"""
mutable struct UserNSRunner <: Runner
    sandbox_cmd::Cmd
    env::Dict{String, String}
    platform::Platform
end

function platform_def_mapping(platform)
    tp = triplet(platform)
    mapping = Pair{String,String}[
        joinpath(shards_cache, tp) => joinpath("/opt", tp)
    ]

    # We might also need the x86_64-linux-gnu platform for bootstrapping,
    # so make sure that's always included
    if platform != Linux(:x86_64)
        ltp = triplet(Linux(:x86_64))
        push!(mapping, joinpath(shards_cache, ltp) => joinpath("/opt", ltp))
    end

    # If we're trying to run macOS and we have an SDK directory, mount that!
    if platform == MacOS()
        sdk_version = "MacOSX10.10.sdk"
        sdk_shard_path = joinpath(shards_cache, sdk_version)
        push!(mapping, sdk_shard_path => joinpath("/opt", tp, sdk_version))
    end

    # Reverse mapping order, because `sandbox` reads them backwards
    reverse!(mapping)
    return mapping
end

function UserNSRunner(workspace_root::String; cwd = nothing,
                      platform::Platform = platform_key(),
                      extra_env=Dict{String, String}(),
                      verbose::Bool = false,
                      mappings = platform_def_mapping(platform))
    # Ensure the rootfs for this platform is downloaded and up to date.
    # Also, since we require the Linux(:x86_64) shard for HOST_CC....
    update_rootfs(triplet.([platform, Linux(:x86_64)]); verbose=verbose)

    # Construct sandbox command
    sandbox_cmd = `$(rootfs_dir("sandbox"))`

    if verbose
        sandbox_cmd = `$sandbox_cmd --verbose`
    end

    sandbox_cmd = `$sandbox_cmd --rootfs $(rootfs_dir())`
    sandbox_cmd = `$sandbox_cmd --workspace $workspace_root`

    if cwd != nothing
        sandbox_cmd = `$sandbox_cmd --cd $cwd`
    end

    for (outside, inside) in mappings
        sandbox_cmd = `$sandbox_cmd --map $outside:$inside`
    end

    # Check to see if we need to run privileged containers.
    if runner_override == "privileged"
        # First, if we're already root, don't do anything.
        if getuid() != 0
            # Next, prefer `sudo`, but allow fallback to `su`
            if success(`sudo -V`)
                sandbox_cmd = `sudo -E $sandbox_cmd`
            else
                sandbox_cmd = `su root -c "$sandbox_cmd"`
            end
        end
    end

    # Finally, return the UserNSRunner in all its glory
    envs = merge(target_envs(triplet(platform)), extra_env)
    return UserNSRunner(sandbox_cmd, envs, platform)
end

function show(io::IO, x::UserNSRunner)
    p = x.platform
    # Displays as, e.g., Linux x86_64 (glibc) UserNSRunner
    write(io, "$(typeof(p).name.name)", " ", arch(p), " ",
          Compat.Sys.islinux(p) ? "($(p.libc)) " : "",
          "UserNSRunner")
end

function Base.run(ur::UserNSRunner, cmd, logpath::AbstractString; verbose::Bool = false, tee_stream=stdout)
    if runner_override == "privileged"
        Compat.@info("Running privileged container via `sudo`, may ask for your password:")
    end

    did_succeed = true
    cd(rootfs_dir()) do
        oc = OutputCollector(setenv(`$(ur.sandbox_cmd) -- $(cmd)`, ur.env); verbose=verbose, tee_stream=tee_stream)

        did_succeed = wait(oc)

        if !isempty(logpath)
            # Write out the logfile, regardless of whether it was successful
            mkpath(dirname(logpath))
            open(logpath, "w") do f
                # First write out the actual command, then the command output
                println(f, cmd)
                print(f, merge(oc))
            end
        end
    end

    # Return whether we succeeded or not
    return did_succeed
end

function run_interactive(ur::UserNSRunner, cmd::Cmd; stdin = nothing, stdout = nothing, stderr = nothing)
    if runner_override == "privileged"
        Compat.@info("Running privileged container via `sudo`, may ask for your password:")
    end

    cd(rootfs_dir()) do
        cmd = setenv(`$(ur.sandbox_cmd) -- $(cmd)`, ur.env)
        if stdin isa Base.AbstractCmd || stdin isa Base.TTY
            cmd = pipeline(cmd, stdin=stdin)
        end
        if stdout isa Base.AbstractCmd || stdout isa Base.TTY
            cmd = pipeline(cmd, stdout=stdout)
        end
        if stderr isa Base.AbstractCmd || stderr isa Base.TTY
            cmd = pipeline(cmd, stderr=stderr)
        end
        
        if stdout isa IOBuffer
            if !(stdin isa IOBuffer)
                stdin = devnull
            end
            out, process = open(cmd, "r", stdin)
            @schedule begin
                while !eof(out)
                    write(stdout, read(out))
                end
            end
            wait(process)
        else
            run(cmd)
        end
    end
end

function runshell(ur::UserNSRunner, args...; kwargs...)
    run_interactive(ur, `/bin/bash`, args...; kwargs...)
end

function runshell(::Type{UserNSRunner}, platform::Platform = platform_key(); verbose::Bool = false)
    ur = UserNSRunner(
        pwd();
        cwd="/workspace/",
        platform=platform,
        verbose=verbose
    )
    return runshell(ur)
end

function probe_unprivileged_containers(;verbose::Bool=false)
    # Ensure the base rootfs is available
    update_rootfs(String[]; verbose=false)

    # Construct an extremely simple sandbox command
    sandbox_cmd = `$(rootfs_dir("sandbox")) --rootfs $(rootfs_dir())`
    cmd = `$(sandbox_cmd) -- /bin/bash -c "echo hello julia"`

    if verbose
        Compat.@info("Probing for unprivileged container capability...")
    end
    oc = OutputCollector(cmd; verbose=verbose, tail_error=false)
    return wait(oc) && merge(oc) == "hello julia\n"
end