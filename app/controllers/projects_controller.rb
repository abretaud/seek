require 'seek/custom_exception'

class ProjectsController < ApplicationController
  include Seek::IndexPager
  include CommonSweepers
  include Seek::DestroyHandling
  include ApiHelper

  before_action :login_required, only: [:guided_join, :guided_create, :request_join, :request_create,
                                        :administer_join_request, :respond_join_request,
                                        :administer_create_project_request, :respond_create_project_request,
                                        :project_join_requests, :project_creation_requests, :typeahead]

  before_action :find_requested_item, only: %i[show admin edit update destroy asset_report admin_members
                                               admin_member_roles update_members storage_report
                                               overview administer_join_request respond_join_request]
  before_action :find_assets, only: [:index]
  before_action :auth_to_create, only: %i[new create,:administer_create_project_request, :respond_create_project_request]
  before_action :is_user_admin_auth, only: %i[manage destroy]
  before_action :editable_by_user, only: %i[edit update]
  before_action :administerable_by_user, only: %i[admin admin_members admin_member_roles update_members storage_report administer_join_request respond_join_request]
  before_action :member_of_this_project, only: [:asset_report], unless: :admin_logged_in?

  before_action :validate_message_log_for_join, only: [:administer_join_request, :respond_join_request]
  before_action :validate_message_log_for_create, only: [:administer_create_project_request, :respond_create_project_request]
  before_action :parse_message_log_details, only: [:administer_create_project_request]
  before_action :check_message_log_programme_permissions, only: [:administer_create_project_request, :respond_create_project_request], if: Proc.new{Seek::Config.programmes_enabled}

  skip_before_action :project_membership_required

  cache_sweeper :projects_sweeper, only: %i[update create destroy]

  include Seek::IsaGraphExtensions

  respond_to :html, :json

  api_actions :index, :show, :create, :update, :destroy

  def project_join_requests
    person = current_person
    @requests = MessageLog.pending_project_join_requests(person.administered_projects)
    respond_to do |format|
      format.html
    end
  end

  def project_creation_requests
    @requests = MessageLog.pending_project_creation_requests.select do |r|
      r.can_respond_project_creation_request?(current_user)
    end
        
    respond_to do |format|
      format.html
    end
  end

  def guided_join
    @project = Project.find(params[:id]) if params[:id]
    respond_to do |format|
      if @project && !@project.allow_request_membership?
        flash[:error] = "Unable to request to join this #{t('project')}, either you are already a member or currently have a pending request"
        format.html { redirect_to(@project) }
      else
        format.html
      end
    end
  end

  def guided_create
    respond_to do |format|
      format.html
    end
  end

  def administer_join_request
    details = JSON.parse(@message_log.details)
    @comments = details['comments']
    @institution = Institution.new(details['institution'])
    @institution = Institution.find(@institution.id) unless @institution.id.nil?

    respond_to do |format|
      format.html
    end
  end

  def respond_join_request
    sender = @message_log.sender
    validation_error_msg=nil;

    if params[:accept_request]=='1'
      inst_params = params.require(:institution).permit([:id, :title, :web_page, :city, :country])
      @institution = Institution.new(inst_params)

      if @institution.id
        @institution = Institution.find(@institution.id)
      else
        if @institution.valid?
          @institution.save!
        else
          validation_error_msg = "The #{t('institution')} is invalid, #{@institution.errors.full_messages.join(', ')}"
        end
      end

      unless validation_error_msg
        sender.add_to_project_and_institution(@project,@institution)
        sender.save!
        Mailer.notify_user_projects_assigned(sender,[@project]).deliver_later
        flash[:notice]="Request accepted and #{sender.name} added to #{t('project')} and notified"
        @message_log.respond('Accepted')
      end
    else
      comments = params['reject_details']
      @message_log.respond(comments)
      Mailer.join_project_rejected(sender,@project,comments).deliver_later
      flash[:notice]="Request rejected and #{sender.name} has been notified"
    end

    if validation_error_msg
      flash.now[:error]=validation_error_msg
      render action: :administer_join_request
    else
      redirect_to(@project)
    end

  end

  def request_join
    @projects = params[:projects].split(',').collect{|id| Project.find(id)}
    raise 'no projects defined' if @projects.empty?
    raise 'email is disabled' unless Seek::Config.email_enabled
    @institution = Institution.find_by_id(params[:institution][:id])
    if @institution.nil?
      inst_params = params.require(:institution).permit([:id, :title, :web_page, :city, :country])
      @institution = Institution.new(inst_params)
    end

    @comments = params[:comments]
    @projects.each do |project|
      if project.allow_request_membership? # protects against malicious spamming
        log = MessageLog.log_project_membership_request(current_user.person, project, @institution, @comments)
        Mailer.request_join_project(current_user, project, @institution.to_json, @comments, log).deliver_later
      end
    end

    flash.now[:notice]="Thank you, your request to join has been sent"
    respond_to do |format|
      format.html
    end
  end

  def request_create
    proj_params = params.require(:project).permit([:title, :web_page, :description])
    @project = Project.new(proj_params)

    @institution = Institution.find_by_id(params[:institution][:id])
    if @institution.nil?
      inst_params = params.require(:institution).permit([:id, :title, :web_page, :city, :country])
      @institution = Institution.new(inst_params)
    end

    # A Programme has been selected, or it is a Site Managed Programme
    if params[:programme_id].present?

      @programme = Programme.find(params[:programme_id])
      raise "no #{t('programme')} can be found" if @programme.nil?
      if @programme.can_manage?
        log = MessageLog.log_project_creation_request(current_person, @programme, @project,@institution)
      elsif @programme.site_managed?
        log = MessageLog.log_project_creation_request(current_person, @programme, @project,@institution)
        Mailer.request_create_project_for_programme(current_user, @programme, @project.to_json, @institution.to_json, log).deliver_later
        Mailer.request_create_project_for_programme_admins(current_user, @programme, @project.to_json, @institution.to_json, log).deliver_later
        flash.now[:notice]="Thank you, your request for a new #{t('project')} has been sent"
      else
        raise 'Invalid Programme'
      end
    # A new project has been requested
    elsif Seek::ProjectFormProgrammeOptions.creation_allowed?
      prog_params = params.require(:programme).permit([:title])
      @programme = Programme.new(prog_params)
      log = MessageLog.log_project_creation_request(current_person, @programme, @project,@institution)
      unless User.admin_logged_in?
        Mailer.request_create_project_and_programme(current_user, @programme.to_json, @project.to_json, @institution.to_json, log).deliver_later
      end
      flash.now[:notice] = "Thank you, your request for a new #{t('programme')} and #{t('project')} has been sent"
    # No Programme at all
    elsif !Seek::ProjectFormProgrammeOptions.show_programme_box?
      @programme=nil
      log = MessageLog.log_project_creation_request(current_person, @programme, @project,@institution)
      unless User.admin_logged_in?
        Mailer.request_create_project(current_user, @project.to_json, @institution.to_json, log).deliver_later
      end
      flash.now[:notice]="Thank you, your request for a new #{t('project')} has been sent"
    end

    if (@programme && @programme.can_manage?) || User.admin_logged_in?
      redirect_to administer_create_project_request_projects_path(message_log_id: log.id)
    else
      respond_to do |format|
        format.html
      end
    end
  end

  def asset_report
    @no_sidebar = true
    project_assets = @project.assets | @project.assays | @project.studies | @project.investigations
    @types = [DataFile, Model, Sop, Presentation, Investigation, Study, Assay]
    @public_assets = {}
    @semi_public_assets = {}
    @restricted_assets = {}
    @types.each do |type|
      action = type.is_isa? ? 'view' : 'download'
      @public_assets[type] = @project.send(type.table_name).authorized_for(action, nil)
      # to reduce the initial list - will start with all assets that can be seen by the first user fouund to be in a project
      user = User.all.detect { |user| !user.try(:person).nil? && !user.person.projects.empty? }
      projects_shared = user.nil? ? [] : @project.send(type.table_name).authorized_for('download', user)
      # now select those with a policy set to downloadable to all-sysmo-users
      projects_shared = projects_shared.select do |item|
        access_type = type.is_isa? ? Policy::VISIBLE : Policy::ACCESSIBLE
        item.policy.access_type == access_type
      end
      # just those shared with sysmo but NOT shared publicly
      @semi_public_assets[type] = projects_shared - @public_assets[type]

      all = project_assets.select { |a| a.class == type }
      @restricted_assets[type] = all - (@semi_public_assets[type] | @public_assets[type])
    end

    # inlinked assets - either not linked to an assay or publication, or in the case of assays not linked to a publication or other assets
    @types_for_unlinked = [DataFile, Model, Sop, Assay]
    @unlinked_to_publication = {}
    @unlinked_to_assay = {}
    @unlinked_assets = {}
    @types_for_unlinked.each do |type|
      @unlinked_assets[type] = []
      @unlinked_to_publication[type] = []
      @unlinked_to_assay[type] = []
    end
    project_assets.each do |asset|
      next unless @types_for_unlinked.include?(asset.class)
      if asset.publications.empty?
        @unlinked_to_publication[asset.class] << asset
      end
      if (!asset.respond_to?(:assays) || asset.assays.empty?) && (!asset.is_isa? || asset.assets.empty?)
        @unlinked_to_assay[asset.class] << asset
      end
    end
    # get those that are unlinked to either
    @types_for_unlinked.each do |type|
      @unlinked_assets[type] = @unlinked_to_assay[type] & @unlinked_to_publication[type]
    end

    respond_to do |format|
      format.html { render template: 'projects/asset_report/report' }
    end
  end

  # GET /projects/1
  # GET /projects/1.xml
  def show
    respond_to do |format|
      format.html # show.html.erb
      format.rdf { render template: 'rdf/show' }
      format.xml
      format.json { render json: @project, include: [params[:include]] }
    end
  end

  # GET /projects/new
  # GET /projects/new.xml
  def new
    @project = Project.new

    possible_unsaved_data = "unsaved_#{@project.class.name}_#{@project.id}".to_sym
    if session[possible_unsaved_data]
      # if user was redirected to this 'edit' page from avatar upload page - use session
      # data; alternatively, user has followed some other route - hence, unsaved session
      # data is most probably not relevant anymore
      if params[:use_unsaved_session_data]
        # NB! these parameters are admin settings and can *occasionally* be used by super-users -
        # regular users won't (and MUST NOT) be able to use these; it's not likely for admins
        # or super-users to modify these along with participating institutions - therefore,
        # it's better not to update these from session
        #
        # this was also causing a bug: when "upload new avatar" pressed, then new picture
        # uploaded and redirected back to edit profile page; at this poing *new* records
        # in the DB for institutions that participate in this project would already be created, which is an
        # error (if the following line is ever to be removed, the bug needs investigation)
        session[possible_unsaved_data][:project].delete(:institution_ids)

        # update those attributes of a project that we want to be updated from the session
        @project.attributes = session[possible_unsaved_data][:project]
        @project.organism_list = session[possible_unsaved_data][:organism][:list] if session[possible_unsaved_data][:organism]
        @project.human_disease_list = session[possible_unsaved_data][:human_disease][:list] if session[possible_unsaved_data][:human_disease]
      end

      # clear the session data anyway
      session[possible_unsaved_data] = nil
    end
  end

  # GET /projects/1/edit
  def edit
    possible_unsaved_data = "unsaved_#{@project.class.name}_#{@project.id}".to_sym
    if session[possible_unsaved_data]
      # if user was redirected to this 'edit' page from avatar upload page - use session
      # data; alternatively, user has followed some other route - hence, unsaved session
      # data is most probably not relevant anymore
      if params[:use_unsaved_session_data]
        # NB! these parameters are admin settings and can *occasionally* be used by super-users -
        # regular users won't (and MUST NOT) be able to use these; it's not likely for admins
        # or super-users to modify these along with participating institutions - therefore,
        # it's better not to update these from session
        #
        # this was also causing a bug: when "upload new avatar" pressed, then new picture
        # uploaded and redirected back to edit profile page; at this poing *new* records
        # in the DB for institutions that participate in this project would already be created, which is an
        # error (if the following line is ever to be removed, the bug needs investigation)
        session[possible_unsaved_data][:project].delete(:institution_ids)

        # update those attributes of a project that we want to be updated from the session
        @project.attributes = session[possible_unsaved_data][:project]
        @project.organism_list = session[possible_unsaved_data][:organism][:list] if session[possible_unsaved_data][:organism]
        @project.human_disease_list = session[possible_unsaved_data][:human_disease][:list] if session[possible_unsaved_data][:human_disease]
      end

      # clear the session data anyway
      session[possible_unsaved_data] = nil
    end
  end

  # POST /projects
  # POST /projects.xml
  def create
    @project = Project.new
    @project.assign_attributes(project_params)
    @project.build_default_policy.set_attributes_with_sharing(params[:policy_attributes]) if params[:policy_attributes]

    respond_to do |format|
      if @project.save
        if params[:default_member] && params[:default_member][:add_to_project] && params[:default_member][:add_to_project] == '1'
          institution = Institution.find(params[:default_member][:institution_id])
          person = current_person
          person.add_to_project_and_institution(@project, institution)
          person.is_project_administrator = true, @project
          disable_authorization_checks { person.save }
        end
        members = params[:project][:members]
        if members.nil?
          members = []
        end
        members.each { | member|
          person = Person.find(member[:person_id])
          institution = Institution.find(member[:institution_id])
          unless person.nil? || institution.nil?
            person.add_to_project_and_institution(@project, institution)
            person.save!
          end
        }
        update_administrative_roles
        flash[:notice] = "#{t('project')} was successfully created."
        format.html { redirect_to(@project) }
        # format.json {render json: @project, adapter: :json, status: 200 }
        format.json { render json: @project, include: [params[:include]] }
      else
        format.html { render action: 'new' }
        format.json { render json: json_api_errors(@project), status: :unprocessable_entity }
      end
    end
  end

  # PUT /projects/1   , polymorphic: [:organism]
  # PUT /projects/1.xml
  def update
    if @project.can_manage?(current_user)
      @project.default_policy = (@project.default_policy || Policy.default).set_attributes_with_sharing(params[:policy_attributes]) if params[:policy_attributes]
    end

    begin
      respond_to do |format|
        if @project.update_attributes(project_params)
          if Seek::Config.email_enabled && !@project.can_manage?(current_user)
            ProjectChangedEmailJob.new(@project).queue_job
          end
          expire_resource_list_item_content
          @project.reload
          flash[:notice] = "#{t('project')} was successfully updated."
          format.html { redirect_to(@project) }
          format.xml  { head :ok }
          format.json { render json: @project, include: [params[:include]] }
        #            format.json {render json: @project, adapter: :json, status: 200 }
        else
          format.html { render action: 'edit' }
          format.xml  { render xml: @project.errors, status: :unprocessable_entity }
          format.json { render json: json_api_errors(@project), status: :unprocessable_entity }
        end
      end
    end
  end

  def manage
    @projects = Project.all
    respond_to do |format|
      format.html
      format.xml { render xml: @projects }
    end
  end

  # returns a list of institutions for a project in JSON format
  def request_institutions
    # listing institutions for a project is public data, but still
    # we require login to protect from unwanted requests

    project_id = params[:id]
    institution_list = nil

    begin
      project = Project.find(project_id)
      institution_list = project.work_groups.collect { |w| [w.institution.title, w.institution.id, w.id] }
      success = true
    rescue ActiveRecord::RecordNotFound
      # project wasn't found
      success = false
    end

    respond_to do |format|
      format.json do
        if success
          render json: { status: 200, institution_list: institution_list }
        else
          render json: { status: 404, error: "Couldn't find #{t('project')} with ID #{project_id}." }
        end
      end
    end
  end

  def admin_members
    respond_with(@project)
  end

  def admin_member_roles
    respond_with(@project)
  end

  def update_members
    current_members = @project.people.to_a
    add_and_remove_members_and_institutions
    @project.reload
    new_members = @project.people.to_a - current_members
    Rails.logger.debug("New members added to project = #{new_members.collect(&:id).inspect}")
    if Seek::Config.email_enabled
      new_members.each do |member|
        Rails.logger.info("Notifying new member: #{member.title}")
        Mailer.notify_user_projects_assigned(member, [@project]).deliver_later
      end
    end
    flag_memberships
    update_administrative_roles

    flash[:notice] = "The members and #{t('institution').pluralize} of the #{t('project').downcase} '#{@project.title}' have been updated"

    respond_with(@project) do |format|
      format.html { redirect_to project_path(@project) }
    end
  end

  def update_administrative_roles
    unless params[:project].blank?
      @project.update_attributes(project_role_params)
    end
  end

  def storage_report
    respond_with do |format|
      format.html do
        render partial: 'projects/storage_usage_content',
               locals: { project: @project, standalone: true }
      end
    end
  end

  def overview

  end

  def administer_create_project_request

    respond_to do |format|
      format.html
    end

  end

  def respond_create_project_request

    requester = @message_log.sender
    make_programme_admin=false

    if params['accept_request']=='1'

      # @programme already populated in before_filter when checking permissions
      make_programme_admin = @programme&.new_record?

      if params['institution']['id']
        @institution = Institution.find(params['institution']['id'])
      else
        @institution = Institution.new(params.require(:institution).permit([:title, :web_page, :city, :country]))
      end

      @project = Project.new(params.require(:project).permit([:title, :web_page, :description]))
      @project.programme = @programme

      validate_error_msg = []

      unless @project.valid?
        validate_error_msg << "The #{t('project')} is invalid, #{@project.errors.full_messages.join(', ')}"
      end
      unless @programme.nil? || @programme.valid?
        validate_error_msg << "The #{t('programme')} is invalid, #{@programme.errors.full_messages.join(', ')}"
      end
      unless @institution.valid?
        validate_error_msg << "The #{t('institution')} is invalid, #{@institution.errors.full_messages.join(', ')}"
      end

      validate_error_msg = validate_error_msg.join('<br/>').html_safe

      if validate_error_msg.blank?
        requester.add_to_project_and_institution(@project, @institution)
        requester.is_project_administrator = true,@project
        requester.is_programme_administrator = true, @programme if make_programme_admin

        disable_authorization_checks do
          requester.save!
        end

        if @message_log.sent_by_self?
          @message_log.destroy
          flash[:notice]="#{t('project')} created"
        else
          @message_log.respond('Accepted')
          flash[:notice]="Request accepted and #{requester.name} added to #{t('project')} and notified"
          Mailer.notify_user_projects_assigned(requester,[@project]).deliver_later
        end

        redirect_to(@project)
      else
        flash.now[:error] = validate_error_msg
        render action: :administer_create_project_request
      end

    else
      if @message_log.sent_by_self?
        @message_log.destroy
        flash[:notice]="#{t('project')} creation cancelled"
      else
        comments = params['reject_details']
        @message_log.respond(comments)
        project_name = JSON.parse(@message_log.details)['project']['title']
        Mailer.create_project_rejected(requester,project_name,comments).deliver_later
        flash[:notice] = "Request rejected and #{requester.name} has been notified"
      end

      redirect_to :root
    end
  end

  def typeahead
    results = Project.where("LOWER(title) LIKE :query
                                    OR LOWER(description) LIKE :query",
                            query: "%#{params[:query].downcase}%").limit(params[:limit] || 10)
    items = results.map do |project|
      { id: project.id,
        name: project.title,
        hint: project.description&.truncate(90, omission: '...') }
    end

    respond_to do |format|
      format.json { render json: items.to_json }
    end
  end

  private

  def project_role_params
    params[:project].keys.each do |k|
      unless params[:project][k].nil?
        params[:project][k] = params[:project][k].split(',')
      else
        params[:project][k] = []
      end
    end

    params.require(:project).permit({ project_administrator_ids: [] },
                                    { asset_gatekeeper_ids: [] },
                                    { asset_housekeeper_ids: [] },
                                    pal_ids: [])
  end

  def project_params
    permitted_params = [:title, :web_page, :wiki_page, :description, { organism_ids: [] }, :parent_id, :start_date,
                        :end_date, :funding_codes, { human_disease_ids: [] },
                        discussion_links_attributes:[:id, :url, :label, :_destroy] ]

    if User.admin_logged_in?
      permitted_params += [:site_root_uri, :site_username, :site_password, :nels_enabled]
    end

    if @project.new_record? || @project.can_manage?(current_user)
      permitted_params += [:use_default_policy, :default_policy, :default_license,
                           { members: [:person_id, :institution_id] }, { project_administrator_ids: [] },
                           { asset_gatekeeper_ids: [] }, { asset_housekeeper_ids: [] }, { pal_ids: [] }]
    end

    if params[:project][:programme_id].present?
      prog = Programme.find_by_id(params[:project][:programme_id])
      if prog&.can_manage? || prog&.allows_user_projects?
        permitted_params += [:programme_id]
      end
    end

    params.require(:project).permit(permitted_params)
  end

  def add_and_remove_members_and_institutions
    groups_to_remove = params[:group_memberships_to_remove] || []
    people_and_institutions_to_add = params[:people_and_institutions_to_add] || []
    groups_to_remove.each do |group|
      group_membership = GroupMembership.find(group)
      next unless group_membership && group_membership.person_can_be_removed?
      # this slightly strange bit of code is required to trigger and after_remove callback, which should be revisted
      #
      # Finn: http://guides.rubyonrails.org/association_basics.html#the-has-many-through-association
      #       "Automatic deletion of join models is direct, no destroy callbacks are triggered."
      group_membership.person.group_memberships.destroy(group_membership)
    end

    people_and_institutions_to_add.each do |new_info|
      json = JSON.parse(new_info)
      person_id = json['person_id']
      institution_id = json['institution_id']
      person = Person.find(person_id)
      institution = Institution.find(institution_id)
      unless person.nil? || institution.nil?
        person.add_to_project_and_institution(@project, institution)
        person.save!
      end
    end
  end

  def flag_memberships
    unless params[:memberships_to_flag].blank?
      GroupMembership.where(id: params[:memberships_to_flag].keys).includes(:work_group).each do |membership|
        if membership.work_group.project_id == @project.id # Prevent modification of other projects' memberships
          left_at = params[:memberships_to_flag][membership.id.to_s][:time_left_at]
          membership.update_attributes(time_left_at: left_at)
        end
        member = Person.find(membership.person_id)
        Rails.cache.delete_matched("rli_title_#{member.cache_key}_.*")
      end
    end
  end

  def editable_by_user
    @project = Project.find(params[:id])
    unless User.admin_logged_in? || @project.can_edit?(current_user)
      error('Insufficient privileges', 'is invalid (insufficient_privileges)', :forbidden)
      return false
    end
  end

  def member_of_this_project
    @project = Project.find(params[:id])
    if @project.nil? || !@project.has_member?(current_user)
      flash[:error] = "You are not a member of this #{t('project')}, so cannot access this page."
      redirect_to project_path(@project)
      false
    else
      true
    end
  end

  def administerable_by_user
    @project = Project.find(params[:id])
    unless @project.can_manage?(current_user)
      error('Insufficient privileges', 'is invalid (insufficient_privileges)', :forbidden)
      return false
    end
  end

  def validate_message_log_for_join
    @message_log = MessageLog.find_by_id(params[:message_log_id])

    error_msg ||= "message log not found" unless @message_log
    error_msg ||= ("message log doesn't match #{t('project')}" if @message_log.subject != @project)
    error_msg ||= ("incorrect type of message log" unless @message_log.message_type==MessageLog::PROJECT_MEMBERSHIP_REQUEST)
    error_msg ||= ("message has already been responded to" if @message_log.responded?)

    if error_msg
      error(error_msg, error_msg)
      return false
    end
  end

  def validate_message_log_for_create
    @message_log = MessageLog.find_by_id(params[:message_log_id])
    error_msg ||= "you do not have permission to respond to this request" unless @message_log.can_respond_project_creation_request?(current_user)
    error_msg ||= "message log not found" unless @message_log
    error_msg ||= ("incorrect type of message log" unless @message_log.message_type==MessageLog::PROJECT_CREATION_REQUEST)
    error_msg ||= ("message has already been responded to" if @message_log.responded?)
    
    if error_msg
      error(error_msg, error_msg)
      return false
    end

  end

  def parse_message_log_details
    details = JSON.parse(@message_log.details)
    if details['programme']
      @programme = Programme.new(details['programme'])
      @programme = Programme.find(@programme.id) unless @programme.id.nil?
    end

    @project = Project.new(details['project'])
    @project = Project.find(@project.id) unless @project.id.nil?

    @institution = Institution.new(details['institution'])
    @institution = Institution.find(@institution.id) unless @institution.id.nil?


  end

  # check programme permissions for responding to a MesasgeLog
  def check_message_log_programme_permissions
    error_msg = nil
    return unless @programme || params['programme']

    unless @programme
      if params['programme']['id']
        @programme = Programme.find(params['programme']['id'])
      else
        @programme = Programme.new(params.require(:programme).permit([:title]))
      end
    end

    if @programme.new_record?
      error_msg = "You need to be an administrator" unless User.admin_logged_in?
    else
      error_msg = "No rights to administer #{t('programme')}" unless @programme.can_manage?
    end

    if error_msg
      error(error_msg, error_msg)
      return false
    end
  end
end
