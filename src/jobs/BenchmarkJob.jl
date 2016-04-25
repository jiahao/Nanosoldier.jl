############################
# Tag Predicate Validation #
############################
# The tag predicate is valid if it is simply a single tag, "ALL", or an
# expression joining multiple tags with the allowed symbols. This validation is
# only to prevent server-side evaluation of arbitrary code. No check is
# performed to ensure that the tag predicate is grammatically correct.

const VALID_TAG_PRED_SYMS = (:!, :&&, :||, :call, :ALL)

function is_valid_tagpred(tagpredstr::AbstractString)
    parsed = parse(tagpredstr)
    if isa(parsed, Expr)
        return is_valid_tagpred(parsed)
    elseif parsed == :ALL
        return true
    else
        return isa(parsed, AbstractString)
    end
end

function is_valid_tagpred(tagpred::Expr)
    if !(in(tagpred.head, VALID_TAG_PRED_SYMS))
        return false
    else
        for item in tagpred.args
            if isa(item, Expr)
                !(is_valid_tagpred(item)) && return false
            elseif isa(item, Symbol)
                !(in(item, VALID_TAG_PRED_SYMS)) && return false
            elseif !(isa(item, AbstractString))
                return false
            end
        end
    end
    return true
end

################
# BenchmarkJob #
################

type BenchmarkJob
    submission::JobSubmission
    tagpred::UTF8String         # predicate string to be fed to @tagged
    against::Nullable{BuildRef} # the comparison build (if available)
end

function BenchmarkJob(submission::JobSubmission)
    tagpred, againststr = parse_benchmark_args(submission.args)
    if !(is_valid_tagpred(tagpred))
        error("invalid tag predicate: $(tagpred)")
    end
    if isnull(againststr)
        against = Nullable{BuildRef}()
    else
        againststr = get(againststr)
        if in(SHA_SEPARATOR, againststr) # e.g. againststr == jrevels/julia@e83b7559df94b3050603847dbd6f3674058027e6
            against = Nullable(BuildRef(split(againststr, SHA_SEPARATOR)...))
        elseif in(BRANCH_SEPARATOR, againststr)
            againstrepo, againstbranch = split(againststr, BRANCH_SEPARATOR)
            against = branchref(submission.config, againstrepo, againstbranch)
        elseif in('/', againststr) # e.g. againststr == jrevels/julia
            against = branchref(submission.config, againststr, "master")
        else # e.g. againststr == e83b7559df94b3050603847dbd6f3674058027e6
            against = Nullable(BuildRef(submission.build.repo, againststr))
        end
    end
    return BenchmarkJob(submission, tagpred, against)
end

function parse_benchmark_args(argstr::AbstractString)
    parsed = parse(argstr)
    # if provided, extract a comparison ref from the trigger arguments
    againststr = Nullable{UTF8String}()
    if (isa(parsed, Expr) && length(parsed.args) == 2 &&
        isa(parsed.args[2], Expr) && parsed.args[2].head == :(=))
        vskv = parsed.args[2].args
        tagpredexpr = parsed.args[1]
        if length(vskv) == 2 && vskv[1] == :vs
            againststr = Nullable(UTF8String(vskv[2]))
        else
            error("malformed comparison argument: $vskv")
        end
    else
        tagpredexpr = parsed
    end
    # If `tagpredexpr` is just a single tag, it'll just be a string, in which case
    # we'll need to wrap it in escaped quotes so that it can be interpolated later.
    if isa(tagpredexpr, AbstractString)
        tagpredstr = string('"', tagpredexpr, '"')
    else
        tagpredstr = string(tagpredexpr)
    end
    return tagpredstr, againststr
end

function branchref(config::Config, reponame::AbstractString, branchname::AbstractString)
    shastr = get(get(GitHub.branch(reponame, branchname; auth = config.auth).commit).sha)
    return Nullable(BuildRef(reponame, shastr))
end

function Base.summary(job::BenchmarkJob)
    result = "BenchmarkJob $(summary(job.primary))"
    if !(isnull(job.against))
        result = "$(result) vs. $(summary(get(job.against)))"
    end
    return result
end

isvalid(submission::JobSubmission, ::Type{BenchmarkJob}) = submission.func == "runbenchmarks"
submission(job::BenchmarkJob) = job.submission

##########################
# BenchmarkJob Execution #
##########################

function Base.run(job::BenchmarkJob)
    node = myid()
    nodelog(config, node, "running primary build for $(summary(job))")
    primary_results = execute_benchmarks!(job, :primary)
    nodelog(config, node, "finished primary build for $(summary(job))")
    results = Dict("primary" => primary_results)
    if !(isnull(job.against))
        nodelog(config, node, "running comparison build for $(summary(job))")
        against_results = execute_benchmarks!(job, :against)
        nodelog(config, node, "finished comparison build for $(summary(job))")
        results["against"] = against_results
        results["judged"] = BenchmarkTools.judge(primary_results, against_results)
    end
    nodelog(cfg, node, "reporting results for $(summary(job))")
    report(job, results)
    nodelog(cfg, node, "completed $(summary(job))")
end

function execute_benchmarks!(job::BenchmarkJob, whichbuild::Symbol)
    cfg = submission(job).config
    build = whichbuild == :against ? get(job.against) : job.submission.build

    if !(cfg.skipbuild)
        # If we're doing the primary build from a PR, feed `buildjulia!` the PR number
        # so that it knows to attempt a build from the merge commit
        if whichbuild == :primary && syjob.submission.fromkind == :pr
            builddir = buildjulia!(cfg, build, job.submission.prnumber)
        else
            builddir = buildjulia!(cfg, build)
        end
        juliapath = joinpath(builddir, "julia")
    else
        juliapath = joinpath(homedir(), "julia-dev/julia-0.5/julia")
    end

    # Execute benchmarks in a new julia process using the fresh build, splicing the tag
    # predicate string into the command. The result is serialized so that we can retrieve it
    # from outside of the new process.
    #
    # This command assumes that all packages are available in the working process's Pkg
    # directory.
    benchname = string(build.sha, "_", whichbuild)
    benchout = joinpath(logdir(cfg),  string(benchname, ".out"))
    bencherr = joinpath(logdir(cfg),  string(benchname, ".err"))
    benchresult = joinpath(resultdir(cfg), string(benchname, ".jld"))
    cmd = """
          benchout = open(\"$(benchout)\", "w"); redirect_stdout(benchout);
          bencherr = open(\"$(bencherr)\", "w"); redirect_stderr(bencherr);
          addprocs(1); # add worker that can be used by parallel benchmarks
          blas_set_num_threads(1); # ensure BLAS threads do not trample each other
          using BaseBenchmarks;
          using BenchmarkTools;
          using JLD;
          println("LOADING SUITE...");
          BaseBenchmarks.loadall!();
          println("FILTERING SUITE...");
          benchmarks = BaseBenchmarks.SUITE[@tagged($(job.tagpred))];
          println("WARMING UP BENCHMARKS...");
          warmup(benchmarks);
          println("RUNNING BENCHMARKS...");
          result = minimum(run(benchmarks; verbose = true));
          println("SAVING RESULT...");
          JLD.save(\"$(benchresult)\", "result", result);
          println("DONE!");
          close(benchout); close(bencherr);
          """

    # Shield the CPU we're working on from the OS. Note that this requires passwordless
    # sudo for cset, which can be set by running `sudo visudo -f /etc/sudoers.d/cpus` and
    # adding the following line:
    #
    #   `user ALL=(ALL:ALL) NOPASSWD:/path/cset`
    #
    # where `user` is replaced by the server's username and `path` is the full path to the
    # `cset` executable.
    run(`sudo cset shield -c $(first(cfg.cpus))`)

    # execute our command on the shielded CPU
    run(`sudo cset shield -e $(juliapath) -- -e $(cmd)`)

    result = JLD.load(benchresult, "result")

    # Get the verbose output of versioninfo for the build, throwing away
    # environment information that is useless/potentially risky to expose.
    try
        build.vinfo = first(split(readstring(`$(juliapath) -e 'versioninfo(true)'`), "Environment"))
    end

    # delete the builddir now that we're done with it
    !(cfg.skipbuild) && rm(builddir, recursive = true)

    return result
end

##########################
# BenchmarkJob Reporting #
##########################

# report job results back to GitHub
function report(job::BenchmarkJob, results)
    node = myid()
    cfg = submission(job).config
    target_url = ""
    if isempty(results["primary"])
        reply_status(job, "error", "no benchmarks were executed")
        reply_comment(job, "[Your benchmark job]($(job.submission.url)) has completed, but no benchmarks were actually executed. Perhaps your tag predicate contains mispelled tags? cc @jrevels")
    else
        # upload raw result data to the report repository
        try
            # To upload in JLD, we'd need to use the Git Data API, which allows uploading
            # of binary blobs. Unfortunately, GitHub.jl doesn't yet implement the Git Data
            # API, so we have to upload a text JSON file instead.
            datapath = joinpath(reportdir(job), "$(reportfile(job)).json")
            datastr = base64encode(JSON.json(results))
            target_url = upload_report_file(job, datapath, datastr, "upload result data for $(summary(job))")
            nodelog(cfg, node, "uploaded $(datapath) to $(cfg.reportrepo)")
        catch err
            nodelog(cfg, node, "error when uploading result JSON file: $(err)")
        end

        # determine the job's final status
        if !(isnull(job.against))
            found_regressions = BenchmarkTools.isregression(results["judged"])
            state = found_regressions ? "failure" : "success"
            status = found_regressions ? "possible performance regressions were detected" : "no performance regressions were detected"
        else
            state = "success"
            status = "successfully executed benchmarks"
        end

        # upload markdown report to the report repository
        try
            reportpath = joinpath(reportdir(job), "$(reportfile(job)).md")
            reportstr = base64encode(sprint(io -> printreport(io, job, results)))
            target_url = upload_report_file(job, reportpath, reportstr, "upload markdown report for $(summary(job))")
            nodelog(cfg, node, "uploaded $(reportpath) to $(cfg.reportrepo)")
        catch err
            nodelog(cfg, node, "error when uploading markdown report: $(err)")
        end

        # reply with the job's final status
        reply_status(job, state, status, target_url)
        if isempty(target_url)
            comment = "[Your benchmark job]($(submission(job).url)) has completed, but something went wrong when trying to upload the result data. cc @jrevels"
        else
            comment = "[Your benchmark job]($(submission(job).url)) has completed - $(status). A full report can be found [here]($(target_url)). cc @jrevels"
        end
        reply_comment(job, comment)
    end
end

reportdir(job::BenchmarkJob) = snipsha(submission(job).build.sha)

function reportfile(job::BenchmarkJob)
    dir = reportdir(job)
    return isnull(job.against) ? dir : "$(dir)_vs_$(snipsha(get(job.against).sha))"
end


# Markdown Report Generation #
#----------------------------#

const REGRESS_MARK = ":x:"
const IMPROVE_MARK = ":white_check_mark:"

function printreport(io::IO, job::BenchmarkJob, results)
    build = submission(job).build
    buildname = string(build.repo, SHA_SEPARATOR, build.sha)
    buildlink = "https://github.com/$(build.repo)/commit/$(build.sha)"
    joblink = "[$(buildname)]($(buildlink))"
    iscomparisonjob = !(isnull(job.against))

    if iscomparisonjob
        againstbuild = get(job.against)
        againstname = string(againstbuild.repo, SHA_SEPARATOR, againstbuild.sha)
        againstlink = "https://github.com/$(againstbuild.repo)/commit/$(againstbuild.sha)"
        joblink = "$(joblink) vs [$(againstname)]($(againstlink))"
        tablegroup = results["judged"]
    else
        tablegroup = results["primary"]
    end

    # print report preface + job properties #
    #---------------------------------------#
    println(io, """
                # Benchmark Report

                ## Job Properties

                *Commit(s):* $(joblink)

                *Tag Predicate:* `$(job.tagpred)`

                *Triggered By:* [link]($(submission(job).url))

                ## Results

                *Note: If Chrome is your browser, I strongly recommend installing the [Wide GitHub](https://chrome.google.com/webstore/detail/wide-github/kaalofacklcidaampbokdplbklpeldpj?hl=en)
                extension, which makes the result table easier to read.*

                Below is a table of this job's results, obtained by running the benchmarks found in
                [JuliaCI/BaseBenchmarks.jl](https://github.com/JuliaCI/BaseBenchmarks.jl). The values
                listed in the `ID` column have the structure `[parent_group, child_group, ..., key]`,
                and can be used to index into the BaseBenchmarks suite to retrieve the corresponding
                benchmarks.

                The percentages accompanying time and memory values in the below table are noise tolerances. The "true"
                time/memory value for a given benchmark is expected to fall within this percentage of the reported value.
                """)

    # print result table #
    #--------------------#
    if iscomparisonjob
        print(io, """
                  The values in the below table take the form `primary_result / comparison_result`. A ratio greater than
                  `1.0` denotes a possible regression (marked with $(REGRESS_MARK)), while a ratio less than `1.0` denotes
                  a possible improvement (marked with $(IMPROVE_MARK)).

                  Only significant results - results that indicate possible regressions or improvements - are shown below
                  (thus, an empty table means that all benchmark results remained invariant between builds).

                  | ID | time ratio | memory ratio |
                  |----|------------|--------------|
                  """)
    else
        print(io, """
                  | ID | time | GC time | memory | allocations |
                  |----|------|---------|--------|-------------|
                  """)
    end

    entries = BenchmarkTools.leaves(tablegroup)

    try
        sort!(entries; lt = leaflessthan)
    end

    for (ids, t) in entries
        if !(iscomparisonjob) || BenchmarkTools.isregression(t) || BenchmarkTools.isimprovement(t)
            println(io, resultrow(ids, t))
        end
    end

    println(io)

    # print list of executed benchmarks #
    #-----------------------------------#
    println(io, """
                ## Benchmark Group List

                Here's a list of all the benchmark groups executed by this job:
                """)

    for id in unique(map(pair -> pair[1][1:end-1], entries))
        println(io, "- `", idrepr(id), "`")
    end

    println(io)

    # print build version info #
    #--------------------------#
    print(io, """
              ## Version Info

              #### Primary Build

              ```
              $(build.vinfo)
              ```
              """)

    if iscomparisonjob
        println(io)
        print(io, """
                  #### Comparison Build

                  ```
                  $(get(job.against).vinfo)
                  ```
                  """)
    end
end

idrepr(id) = (str = repr(id); str[searchindex(str, '['):end])

idlessthan(a::Tuple, b::Tuple) = isless(a, b)
idlessthan(a, b::Tuple) = false
idlessthan(a::Tuple, b) = true
idlessthan(a, b) = isless(a, b)

function leaflessthan(kv1, kv2)
    k1 = kv1[1]
    k2 = kv2[1]
    for i in eachindex(k1)
        if idlessthan(k1[i], k2[i])
            return true
        elseif k1[i] != k2[i]
            return false
        end
    end
    return false
end

function resultrow(ids, t::BenchmarkTools.TrialEstimate)
    t_tol = BenchmarkTools.prettypercent(BenchmarkTools.params(t).time_tolerance)
    m_tol = BenchmarkTools.prettypercent(BenchmarkTools.params(t).memory_tolerance)
    timestr = string(BenchmarkTools.prettytime(BenchmarkTools.time(t)), " (", t_tol, ")")
    memstr = string(BenchmarkTools.prettymemory(BenchmarkTools.memory(t)), " (", m_tol, ")")
    gcstr = BenchmarkTools.prettytime(BenchmarkTools.gctime(t))
    allocstr = string(BenchmarkTools.allocs(t))
    return "| `$(idrepr(ids))` | $(timestr) | $(gcstr) | $(memstr) | $(allocstr) |"
end

function resultrow(ids, t::BenchmarkTools.TrialJudgement)
    t_tol = BenchmarkTools.prettypercent(BenchmarkTools.params(t).time_tolerance)
    m_tol = BenchmarkTools.prettypercent(BenchmarkTools.params(t).memory_tolerance)
    t_ratio = @sprintf("%.2f", BenchmarkTools.time(BenchmarkTools.ratio(t)))
    m_ratio =  @sprintf("%.2f", BenchmarkTools.memory(BenchmarkTools.ratio(t)))
    t_mark = resultmark(BenchmarkTools.time(t))
    m_mark = resultmark(BenchmarkTools.memory(t))
    timestr = "$(t_ratio) ($(t_tol)) $(t_mark)"
    memstr = "$(m_ratio) ($(m_tol)) $(m_mark)"
    return "| `$(idrepr(ids))` | $(timestr) | $(memstr) |"
end

resultmark(sym::Symbol) = sym == :regression ? REGRESS_MARK : (sym == :improvement ? IMPROVE_MARK : "")