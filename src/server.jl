
immutable Server
    config::Config
    jobs::Vector{AbstractJob}
    listener::GitHub.CommentListener
    function Server(config::Config)
        jobs = Vector{AbstractJob}()

        # This closure is the CommentListener's handle function, which validates the
        # trigger phrase and converts the event payload into a J <: AbstractJob. This
        # job then gets added to the `jobs` queue, which is monitored and resolved by
        # the job-feeding tasks scheduled when `run` is called on the Server.
        handle = (event, phrase) -> begin
            nodelog(config, 1, "recieved job submission with phrase $phrase")
            if event.kind == "issue_comment" && !(haskey(event.payload["issue"], "pull_request"))
                return HttpCommon.Response(400, "nanosoldier jobs cannot be triggered from issue comments (only PRs or commits)")
            end
            if haskey(event.payload, "action") && !(in(event.payload["action"], ("created", "opened")))
                return HttpCommon.Response(204, "no action taken (submission was from an edit, close, or delete)")
            end
            submission = JobSubmission(config, event, phrase)
            addedjob = false
            for J in subtypes(AbstractJob)
                if isvalid(submission, J)
                    try
                        job = J(submission)
                        push!(jobs, job)
                        reply_status(job, "pending", "job added to queue: $(summary(job))")
                        addedjob = true
                    catch err
                        nodelog(config, 1, "failed to constuct $(J) with a supposedly valid submission: $(err)")
                    end
                end
            end
            if !(addedjob)
                reply_status(submission, "error", "invalid job submission; check syntax")
                HttpCommon.Response(400, "invalid job submission")
            end
            return HttpCommon.Response(202, "recieved job submission")
        end

        listener = GitHub.CommentListener(handle, TRIGGER;
                                          auth = config.auth,
                                          secret = config.secret,
                                          repos = [config.trackrepo])
        return new(config, jobs, listener)
    end
end

function Base.run(server::Server, args...; kwargs...)
    @assert myid() == 1 "Nanosoldier server must be run from the master node"
    persistdir!(workdir(server.config))
    # Schedule a task for each node that feeds the node a job from the
    # queque once the node has completed its primary job. If the queue is
    # empty, then the task will call `yield` in order to avoid a deadlock.
    for node in server.config.nodes
        @schedule begin
            try
                while true
                    if isempty(server.jobs)
                        yield()
                    else
                        job = shift!(server.jobs)
                        message = "running on node $(node): $(summary(job))"
                        reply_status(job, "pending", message)
                        nodelog(server.config, node, message)
                        try
                            remotecall_fetch(persistdir!, node, server.config)
                            remotecall_fetch(run, node, job)
                            nodelog(server.config, node, "completed job: $(summary(job))")
                        catch err
                            err = isa(err, RemoteException) ? err.captured.ex : err
                            err_str = string(err)
                            message = "Something went wrong when running [your job]($(submission(job).url)):\n```\n$(err_str)\n```"
                            if isa(err, NanosoldierError)
                                if isempty(err.url)
                                    message *= "Unfortunately, the logs could not be uploaded.\n"
                                else
                                    message *= "Logs and partial data can be found [here]($(err.url))\n"
                                end
                            end
                            message *= "cc @jrevels"
                            nodelog(server.config, node, err_str)
                            reply_status(job, "error", err_str)
                            reply_comment(job, message)
                        end
                    end
                    sleep(5) # poll only every 5 seconds so as not to throttle CPU
                end
            catch err
                nodelog(server.config, node, "encountered task error: $(err)")
                rethrow(err)
            end
        end
    end
    return run(server.listener, args...; kwargs...)
end
