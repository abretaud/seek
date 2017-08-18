class StudiesController < ApplicationController
  include Seek::IndexPager
  include Seek::AssetsCommon

  before_filter :find_assets, only: [:index]
  before_filter :find_and_authorize_requested_item, only: %i[edit update destroy show new_object_based_on_existing_one]

  # project_membership_required_appended is an alias to project_membership_required, but is necesary to include the actions
  # defined in the application controller
  before_filter :project_membership_required_appended, only: [:new_object_based_on_existing_one]

  before_filter :check_assays_are_not_already_associated_with_another_study, only: %i[create update]

  include Seek::Publishing::PublishingCommon

  include Seek::AnnotationCommon

  include Seek::BreadCrumbs

  include Seek::IsaGraphExtensions

  def new_object_based_on_existing_one
    @existing_study = Study.find(params[:id])

    if @existing_study.can_view?
      @study = @existing_study.clone_with_associations
      unless @existing_study.investigation.can_edit?
        @study.investigation = nil
        flash.now[:notice] = "The #{t('investigation')} associated with the original #{t('study')} cannot be edited, so you need to select a different #{t('investigation')}"
      end
      render action: 'new'
    else
      flash[:error] = "You do not have the necessary permissions to copy this #{t('study')}"
      redirect_to study_path(@existing_study)
    end
  end

  def new
    @study = Study.new
    @study.create_from_asset = params[:create_from_asset]
    @study.new_link_from_assay = params[:new_link_from_assay]
    investigation = nil
    investigation = Investigation.find(params[:investigation_id]) if params[:investigation_id]

    if investigation
      if investigation.can_edit?
        @study.investigation = investigation
      else
        flash.now[:error] = "You do not have permission to associate the new #{t('study')} with the #{t('investigation')} '#{investigation.title}'."
      end
    end
    investigations = Investigation.all.select(&:can_view?)
    respond_to do |format|
      if investigations.blank?
        flash.now[:notice] = "No #{t('investigation')} available, you have to create a new one before creating your Study!"
      end
      format.html
    end
  end

  def edit
    @study = Study.find(params[:id])
    respond_to do |format|
      format.html
      format.xml
    end
  end

  def update
    @study = nil
    params_to_update = nil
    if @is_json
      @study=Study.find(params["data"][:id])
      organize_policies_from_json
      params_to_update = ActiveModelSerializers::Deserialization.jsonapi_parse(params)
      return if !validate_person_responsible(params_to_update)
    else
      @study = Study.find(params[:id])
      params_to_update = study_params
    end
    Rails.logger.info(params_to_update)

    if @study.present?
      @study.attributes = params_to_update
      update_sharing_policies @study

      respond_to do |format|
        if @study.save
          update_scales @study
          update_relationships(@study, params)

          flash[:notice] = "#{t('study')} was successfully updated."
          format.html { redirect_to(@study) }
          format.json {render json: JSONAPI::Serializer.serialize(@study)}
        else
          format.html { render action: 'edit' }
          format.json { render json: {error: @study.errors, status: :unprocessable_entity}, status: :unprocessable_entity }
        end
      end
    end
  end

  def show
    @study = Study.find(params[:id])
    @study.create_from_asset = params[:create_from_asset]
    options = {:is_collection=>false}

    respond_to do |format|
      format.html
      format.xml
      format.rdf { render template: 'rdf/show' }
      format.json {render json: JSONAPI::Serializer.serialize(@study,options)}

    end
  end

  def create
    @study = nil
    if @is_json
      organize_policies_from_json
      return if !validate_person_responsible(params["data"]["attributes"])
      @study = Study.new(ActiveModelSerializers::Deserialization.jsonapi_parse(params))
    else
      @study = Study.new(study_params)
    end
    if @study.present?
      update_sharing_policies @study
    end

    if @study.present? && @study.save
      update_scales @study
      update_relationships(@study, params)

      if @study.new_link_from_assay == 'true'
        render partial: 'assets/back_to_singleselect_parent', locals: { child: @study, parent: 'assay' }
      else
        respond_to do |format|
          flash[:notice] = "The #{t('study')} was successfully created.<br/>".html_safe
          if @study.create_from_asset == 'true'
            flash.now[:notice] << "Now you can create new #{t('assays.assay')} by clicking -Add an #{t('assays.assay')}- button".html_safe
            format.html { redirect_to study_path(id: @study, create_from_asset: @study.create_from_asset) }
            format.json {render json: JSONAPI::Serializer.serialize(@study)}
          else
            format.html { redirect_to study_path(@study) }
            format.json {render json: JSONAPI::Serializer.serialize(@study)}
          end
        end
      end
    else
      respond_to do |format|
        format.html { render action: 'new' }
        format.json { render json: {error: @study.errors, status: :unprocessable_entity}, status: :unprocessable_entity }
      end
    end
  end

  def investigation_selected_ajax
    if (investigation_id = params[:investigation_id] && params[:investigation_id] != '0')
      investigation = Investigation.find(investigation_id)
      people = investigation.projects.collect(&:people).flatten
    end

    people ||= []

    render :update do |page|
      page.replace_html 'person_responsible_collection', partial: 'studies/person_responsible_list', locals: { people: people }
    end
  end

  def check_assays_are_not_already_associated_with_another_study
    assay_ids = params[:study][:assay_ids]
    study_id = params[:id]
    if assay_ids
      valid = !assay_ids.detect do |a_id|
        a = Assay.find(a_id)
        !a.study.nil? && a.study_id.to_s != study_id
      end
      unless valid
        unless valid
          error("Cannot add an #{t('assays.assay')} already associated with a Study", "is invalid (invalid #{t('assays.assay')})")
          return false
        end
      end
    end
  end

  private
  def validate_person_responsible(p)
    if (!p[:person_responsible_id].nil?) && (!Person.exists?(p[:person_responsible_id]))
      render json: {error: "Person responsible does not exist", status: :unprocessable_entity}, status: :unprocessable_entity
      return false
    end
    true
  end

  def study_params
    params.require(:study).permit(:title, :description, :experimentalists, :investigation_id, :person_responsible_id,
                                  :other_creators, :create_from_asset, :new_link_from_assay)
  end
end
