require 'travis/builder'

class BuildsController < ApplicationController
  respond_to :json
  before_filter :authenticate_user!, :except => [:index, :show]
  skip_before_filter :verify_authenticity_token

  def index
    if repository = Repository.find(params[:repository_id])
      render :json => repository.builds.started.order('id DESC').limit(10).as_json
    end
  end

  def show
    build = Build.find(params[:id])
    render :json => build.as_json
  end

  def create
    if build = Build.create_from_github_payload(params[:payload])
      build.save!
      enqueue!(build)
      build.repository.update_attributes!(:last_built_at => Time.now) # TODO the build isn't actually started now
    end
    render :nothing => true
  end

  def update
    build = Build.find(params[:id])
    build.update_attributes!(params[:build])

    if build.was_started?
      trigger('build:started', build, 'msg_id' => params[:msg_id])
    elsif build.matrix_expanded?
      build.matrix.each { |child| enqueue!(child) }
      trigger('build:expanded', build, 'msg_id' => params[:msg_id])
    elsif build.was_finished?
      trigger('build:finished', build, 'msg_id' => params[:msg_id])
      deliver_finished_email(build)
    end

    render :nothing => true
  end

  def log
    build = Build.find(params[:id])
    build.append_log!(params[:build][:log]) unless build.finished?
    trigger('build:log', build, 'build' => { '_log' => params[:build][:log] }, 'msg_id' => params[:msg_id])
    render :nothing => true
  end

  protected

    def enqueue!(build)
      Travis::Builder.class_eval { @queue = build.repository.name == 'rails' ? 'rails' : 'builds' } # FIXME OH SHI~
      job  = Travis::Builder.enqueue(json_for(:job, build))
      build.update_attributes!(:job_id => job.meta_id)
      trigger('build:queued', build)
    end

    def deliver_finished_email(build)
      BuildMailer.finished_email(build.parent || build).deliver if build.send_notifications?
    rescue Net::SMTPError => e
      # TODO might want to log this event. e.g. happens when people specify bad email addresses like "foo[at]bar[dot]com"
    end

    def trigger(event, build, data = {})
      push(event, json_for(event, build).deep_merge(data))
      trigger(event, build.parent) if event == 'build:finished' && build.parent.try(:finished?)
    end

    def json_for(event, build)
      { 'build' => build.as_json(:for => event.to_sym), 'repository' => build.repository.as_json(:for => event.to_sym) }
    end

    def push(event, data)
      Pusher[event == 'build:queued' ? 'jobs' : 'repositories'].trigger(event, data)
    end
end
