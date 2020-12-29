# frozen_string_literal: true

require 'ostruct'
require 'uri'
require 'yaml'

require 'paint'

require 'orbital/command'
require 'orbital/spinner/polling_spinner'
require 'orbital/github/client'
require 'orbital/github/log_dump'

class Net::HTTPRequest
  attr_accessor :body_doc
end

module Orbital; end
module Orbital::Commands; end
class Orbital::Commands::Trigger < Orbital::Command
  def initialize(*args)
    super(*args)

    @options.input ||= {}
    if @options.input.kind_of?(Array)
      @options.input = @options.input.map do |kv|
        k, v = kv.split('=', 2)
        [k.intern, v]
      end.to_h
    end

    unless @options.workflow.end_with?('.yml') or @options.workflow.end_with?('.yaml')
      @options.workflow += '.yml'
    end

    case @options.repo
    when 'app', 'deployment'
      @options.repo = @options.repo.intern
    when /^(\w+)\/(\w+)$/
      # leave as-is
    else
      logger.fatal "invalid value for flag --repo"
    end

    case @options.repo
    when :app
      @options.repo = @context.project.appctl.app_repo.uri.path[1..-1]
      @options.branch ||= @context.project.appctl.app_repo.default_branch
    when :deployment
      @options.repo = @context.project.appctl.deployment_repo.uri.path[1..-1]
      @options.branch ||= @context.project.appctl.deployment_repo.default_branch
    else
      @options.branch ||= "master"
    end

    @github = Orbital::Github::Client.new(@context.project.root)
  end

  def add_inputs(hsh)
    hsh.each do |k, v|
      @options.input[k] = v
    end
  end

  def execute(input: $stdin, output: $stdout)
    newest_workflow_run_id_before = @github.newest_workflow_run_id(
      @options.repo,
      @options.workflow
    )

    logger.success "get ID of last workflow-run"

    @github.create_workflow_dispatch(
      @options.repo,
      @options.workflow,
      @options.branch,
      @options.input.to_h.map{ |k, v| [k.to_s, v.to_s] }.to_h
    )

    logger.success ["send ", Paint["workflow_dispatch", :italic], " event"]

    newest_workflow_run_id_after =
      Orbital::Spinner::SimplePollingSpinner.new(
        wait_text: "get ID of new workflow-run",
        poll: lambda{ |_|
          @github.newest_workflow_run_id(
            @options.repo,
            @options.workflow,
          )
        },
        accept: lambda{ |result|
          result and result != newest_workflow_run_id_before
        }
      ).run.result

    logger.step "monitor workflow progress"

    workflow_poller =
      self.monitor_workflow_progress(newest_workflow_run_id_after)

    if workflow_poller.state == :failure
      job_id = workflow_poller.result['id']

      log :break
      logger.info [
        "Please ",
        link_to(
          "https://github.com/#{@options.repo}/runs/#{job_id}?check_suite_focus=true",
          "visit the Github Actions job-detail view for this job"
        ),
        " to learn more."
      ]
    end

    workflow_poller.state == :success
  end

  class MonitorWorkflowProgressPoller < Orbital::Spinner::PollingSpinner
    attr_accessor :poll_fn

    def poll
      @poll_fn.call(@result)
    end

    def state
      if @result and @result['conclusion'] == 'success'
        :success
      elsif @result and @result['conclusion'] == 'failure' and @result['logs']
        :failure
      elsif @poll_attempts > 0
        :in_progress
      else
        :queued
      end
    end

    def resolved?
      not([:in_progress, :queued].include?(self.state))
    end

    def erase_lns(num_lns)
      "\e[#{num_lns}A\e[J"
    end

    def draw(mode)
      if @prev_lines_drawn and @prev_lines_drawn > 0
        $stdout.write(erase_lns(@prev_lines_drawn))
      end

      job_desc = @result ? render_job(@result).to_flat_string : ""

      if job_desc.length > 0
        $stdout.write(job_desc)
      end

      @prev_lines_drawn = job_desc.count("\n")
    end

    def format_line_with_state(state, str)
      case state
      when :success
        [Paint["✓", :green], " ", str]
      when :success_pointless
        [Paint["✓", :yellow], " ", str]
      when :failure
        [Paint["✘", :red], " ", Paint[str.to_flat_string, :bold]]
      when :skipped
        [Paint["↯", :yellow], " ", "\e[9m", str, "\e[0m"]
      when :in_progress
        [Paint[@animations[:working].to_s, :blue], " ", Paint[[str, "…"].to_flat_string, :bold]]
      when :error_in_progress
        [Paint[@animations[:working].to_s, :red], " ", Paint[[str, "…"].to_flat_string, :red, :italic]]
      when :queued
        Paint[[@animations[:waiting].to_s, " ", str].to_flat_string, [192, 192, 192]]
      end
    end

    def render_job(job)
      job_state = (job['conclusion'] || job['status']).intern
      job_desc = [format_line_with_state(job_state, ["job '", job['name'], "'"]), "\n"]

      error_report_for_failed_step =
        if job_state == :failure and job['logs']
          job['logs'].to_error_report("      ")
        end

      prev_step_failed = false

      job_step_descs = job['steps'].map do |step|
        step_state = (step['conclusion'] || step['status']).intern

        if step_state == :success and prev_step_failed
          step_state = :success_pointless
        end

        step_desc = ["  ", format_line_with_state(step_state, step['name']), "\n"]

        if step_state == :failure
          step_desc.push(
            if error_report_for_failed_step
              error_report_for_failed_step
            else
              ["      ", format_line_with_state(:error_in_progress, ["retrieving error log"]), "\n"]
            end
          )

          prev_step_failed = true
        end

        step_desc
      end

      [job_desc, job_step_descs]
    end
  end

  def monitor_workflow_progress(run_id)
    poller = MonitorWorkflowProgressPoller.new

    poller.poll_fn = lambda do |result|
      if result and result['conclusion'] == 'failure'
        unless result['logs']
          logs = @github.download_job_logs(
            @options.repo,
            result['id']
          )

          if logs
            result['logs'] = Orbital::Github::LogDump.parse(logs)
          end
        end

        result
      elsif result and result['conclusion'] == 'success'
        result
      else
        begin
          @github.first_workflow_run_job(
            @options.repo,
            run_id
          )
        rescue Net::HTTPServerException => e
          nil
        end
      end
    end

    poller.run

    poller
  end
end
