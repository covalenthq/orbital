require 'uri'
require 'net/http'
require 'json'

module Orbital; end
module Orbital::Github; end

class Orbital::Github::Client
  BASE_ENDPOINT = URI("https://api.github.com/")
  LOGS_ENPDOINT = URI("https://pipelines.actions.githubusercontent.com/")

  def initialize(worktree_root)
    @worktree_root = worktree_root
    @username = ENV['GH_USER'] || at_worktree_root{ `git config github.user`.strip }
    @password = ENV['GH_TOKEN'] || at_worktree_root{ `git config github.token`.strip }
    @conn_pool = {}
  end

  def at_worktree_root
    Dir.chdir(@worktree_root.to_s) do
      yield
    end
  end

  def configure_request(req)
    if req.uri.hostname == BASE_ENDPOINT.hostname
      req.basic_auth(@username, @password)

      req['Accept'] = 'application/vnd.github.v3+json'
    end

    if req.body_doc
      req['Content-Type'] = 'application/json'
      new_body =
        case req.body_doc
        when String
          req.body_doc
        else
          req.body_doc.to_json
        end
      req.body = new_body
    end

    req
  end

  def create_workflow_dispatch(*args)
    self.request(self.endpoint_create_workflow_dispatch(*args))
  end

  def newest_workflow_run_id(repo, workflow)
    resp = self.request(self.endpoint_list_workflow_runs(repo, workflow))
    run = resp["workflow_runs"].sort_by{ |run| run["created_at"] }.last
    run["id"] if run
  end

  def first_workflow_run_job(repo, run_id)
    resp = self.request(self.endpoint_list_workflow_run_jobs(repo, run_id))
    job = resp["jobs"].first
  end

  def download_job_logs(repo, job_id)
    self.request(self.endpoint_download_job_logs(repo, job_id))
  end

  def retry_until_success(method_name, args)
    while true
      begin
        resp = self.send(method_name, *args)
        return resp if resp != nil
      rescue Net::HTTPServerException => e
        Kernel.sleep(rand(0.5) + 0.25)
      end
    end
  end


  def endpoint_download_job_logs(repo, job_id)
    Net::HTTP::Get.new(BASE_ENDPOINT.merge("/repos/#{repo}/actions/jobs/#{job_id}/logs"))
  end

  def endpoint_list_workflow_run_jobs(repo, run_id)
    req_uri = BASE_ENDPOINT.merge("/repos/#{repo}/actions/runs/#{run_id}/jobs")
    req_uri.query = URI.encode_www_form({filter: "latest"})
    Net::HTTP::Get.new(req_uri)
  end

  def endpoint_create_workflow_dispatch(repo, workflow, branch_ref, inputs)
    req = Net::HTTP::Post.new(BASE_ENDPOINT.merge("/repos/#{repo}/actions/workflows/#{workflow}/dispatches"))
    req.body_doc = {
      "ref" => branch_ref,
      "inputs" => inputs
    }
    req
  end

  def endpoint_list_workflow_runs(repo, workflow)
    Net::HTTP::Get.new(BASE_ENDPOINT.merge("/repos/#{repo}/actions/workflows/#{workflow}/runs"))
  end

  def checkout_conn(req)
    pool_key = req.uri.hostname
    return @conn_pool[pool_key] if @conn_pool.has_key?(pool_key)

    conn = Net::HTTP.start(req.uri.hostname, req.uri.port, use_ssl: req.uri.scheme == 'https')
    @conn_pool[pool_key] = conn
    conn
  end

  def request(req, limit = 5)
    raise ArgumentError, 'too many HTTP redirects' if limit == 0

    req = configure_request(req)

    conn = checkout_conn(req)

    resp = conn.request(req)

    case resp
    when Net::HTTPSuccess
      if (resp['content-type'] || '').include?('json')
        JSON.parse(resp.body)
      else
        resp.body
      end
    when Net::HTTPRedirection
      next_uri = URI(resp['Location'])
      # puts "redirected to: #{next_uri.to_s}"
      next_req = Net::HTTP::Get.new(next_uri)
      request(next_req, limit - 1)
    else
      resp.value
    end
  end
end
