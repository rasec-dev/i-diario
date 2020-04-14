require "application_responder"

class ApplicationController < ActionController::Base
  MAX_STEPS_FOR_SCHOOL_CALENDAR = 4

  self.responder = ApplicationResponder
  respond_to :html

  include BootstrapFlashHelper
  include Pundit
  skip_around_filter :set_locale_from_url
  around_action :handle_customer
  before_action :set_honeybadger_context
  around_filter :set_user_current
  around_filter :set_thread_origin_type

  respond_to :html, :json

  # Prevent CSRF attacks by raising an exception.
  # For APIs, you may want to use :null_session instead.
  #protect_from_forgery with: :exception
  protect_from_forgery with: :null_session

  before_action :check_entity_status
  before_action :authenticate_user!
  before_action :configure_permitted_parameters, if: :devise_controller?
  before_action :check_for_notifications, if: :user_signed_in?
  before_action :check_for_current_user_role, if: :user_signed_in?

  has_scope :q do |controller, scope, value|
    scope.search(value).limit(10)
  end

  has_scope :filter, type: :hash do |controller, scope, value|
   filters = value.select { |filter_name, filter_value| filter_value.present? }
   filters.each do |filter_name, filter_value|
     scope = scope.send(filter_name, filter_value)
   end

   scope
 end

  rescue_from Pundit::NotAuthorizedError, with: :user_not_authorized
  rescue_from IeducarApi::Base::ApiError, with: :rescue_from_api_error

  protected

  with_options to: :current_user, allow_nil: true do
    delegate :current_unity, :current_teacher, :current_teacher_id, :can_change_school_year, :current_school_year
    delegate :classroom, :discipline, prefix: true
  end
  helper_method :current_teacher
  helper_method :current_teacher_id
  helper_method :current_unity
  helper_method :current_user_classroom
  helper_method :current_user_discipline
  helper_method :can_change_school_year?

  def page
    params[:page] || 1
  end

  def per
    params[:per] || 10
  end

  def policy(record)
    ApplicationPolicy.new(current_user, record)
  end
  helper_method :policy

  def handle_customer(&block)
    if current_entity
      current_entity.using_connection(&block)
    else
      redirect_to '/404'
    end
  end

  def check_entity_status
    redirect_to disabled_entity_path if current_entity.disabled
  end

  def configure_permitted_parameters
    devise_parameter_sanitizer.for(:sign_in) do |u|
      u.permit(:credentials, :password, :remember_me)
    end

    devise_parameter_sanitizer.for(:account_update) do |u|
      u.permit(:email, :first_name, :last_name, :login, :phone, :cpf, :current_password, :authorize_email_and_sms)
    end

    devise_parameter_sanitizer.for(:sign_up) do |u|
      u.permit(:email, :password, :password_confirmation)
    end
  end

  def after_sign_in_path_for(resource_or_scope)
    if !!current_user.receive_news == current_user.receive_news
      super
    else
      flash[:info] = "É importante que seu cadastro no sistema esteja atualizado. Desta forma você poderá receber novidades sobre o produto. Por favor, atualize aqui suas preferências de e-mail."
      edit_account_path
    end
  end

  def check_for_notifications
    synchronizations = current_user.synchronizations.unnotified

    return unless synchronizations.exists?

    if (synchronization = synchronizations.completed_unnotified)
      flash.now[:notice] = t('ieducar_api_synchronization.completed')
    elsif (synchronization = current_user.synchronizations.last_error)
      flash.now[:alert] = t('ieducar_api_synchronization.error', error: error_by_user(current_user))
    end

    synchronization&.notified!
  end

  def check_for_current_user_role
    flash.now[:warning] = t('current_role.check.warning') unless valid_current_role?
  end

  def current_entity_configuration
    @current_entity_configuration ||= EntityConfiguration.first
  end
  helper_method :current_entity_configuration

  def current_entity
    @current_entity ||= Entity.find_by(domain: request.host)
    Entity.current = @current_entity
  end
  helper_method :current_entity

  def current_configuration
    @current_configuration ||= IeducarApiConfiguration.current
  end
  helper_method :current_configuration

  def user_not_authorized(exception)
    policy_name = exception.policy.class.to_s.underscore

    flash[:error] = t "#{policy_name}.#{exception.query}", scope: "pundit", default: :default
    redirect_to(root_path)
  end

  def rescue_from_api_error(exception)
    redirect_to edit_ieducar_api_configurations_path, alert: exception.message
  end

  def current_school_calendar
    @current_school_calendar ||=
      begin
        return if current_user.admin? && current_unity.blank?

        CurrentSchoolCalendarFetcher.new(
          current_unity,
          current_user_classroom,
          current_school_year
        ).fetch
      end
  end
  helper_method :current_school_calendar

  def current_test_setting
    TestSettingFetcher.current(current_user.try(:current_classroom)) || default_test_setting
  end

  def default_test_setting
    TestSettingFetcher.by_step(steps_fetcher.steps.first)
  end

  def steps_fetcher
    @steps_fetcher ||= StepsFetcher.new(current_user_classroom)
  end

  def require_current_teacher
    return if current_teacher

    flash[:alert] = t('errors.general.require_current_teacher')

    redirect_to root_path
  end

  def require_current_clasroom
    return if current_user_classroom

    flash[:alert] = t('errors.general.require_current_classroom')

    redirect_to root_path
  end

  def require_current_teacher_discipline_classrooms
    return if current_teacher&.teacher_discipline_classrooms.any?

    flash[:alert] = t('errors.general.require_current_teacher_discipline_classrooms')

    redirect_to root_path
  end

  def require_allow_to_modify_prev_years
    return if can_change_school_year?
    return if (first_step_start_date_for_posting..last_step_end_date_for_posting).to_a.include?(Date.current)

    flash[:alert] = t('errors.general.not_allowed_to_modify_prev_years')
    redirect_to root_path
  end

  def valid_current_role?
    CurrentRoleForm.new(
      current_user: current_user,
      current_user_role: current_user.current_user_role,
      current_classroom: current_user.current_classroom,
      current_discipline_id: current_user.current_discipline_id,
      current_unity: current_user.current_unity,
      current_teacher: current_user.current_teacher,
      current_school_year: current_user.current_school_year
    ).valid?
  end

  def teacher_discipline_score_type
    return DisciplineScoreTypes::NUMERIC if current_user_classroom.exam_rule.score_type == ScoreTypes::NUMERIC
    return DisciplineScoreTypes::CONCEPT if current_user_classroom.exam_rule.score_type == ScoreTypes::CONCEPT
    TeacherDisciplineClassroom.find_by(teacher: current_teacher, discipline: current_user_discipline).score_type if current_user_classroom.exam_rule.score_type == ScoreTypes::NUMERIC_AND_CONCEPT
  end

  def current_user_is_employee_or_administrator?
    current_user.assumed_teacher_id.blank? && current_user.current_role_is_admin_or_employee?
  end

  def teacher_differentiated_discipline_score_type
    exam_rule = current_user_classroom.exam_rule
    differentiated_exam_rule = exam_rule.differentiated_exam_rule
    return teacher_discipline_score_type unless differentiated_exam_rule.present?
    return teacher_discipline_score_type unless current_user_classroom.has_differentiated_students?
    return DisciplineScoreTypes::NUMERIC if differentiated_exam_rule.score_type == ScoreTypes::NUMERIC
    return DisciplineScoreTypes::CONCEPT if differentiated_exam_rule.score_type == ScoreTypes::CONCEPT
    TeacherDisciplineClassroom.find_by(teacher: current_teacher, discipline: current_user_discipline).score_type if differentiated_exam_rule.score_type == ScoreTypes::NUMERIC_AND_CONCEPT
  end

  def set_user_current
    User.current = current_user

    begin
      yield
    ensure
      User.current = nil
    end
  end

  def set_thread_origin_type
    Thread.current[:origin_type] = OriginTypes::WEB

    begin
      yield
    ensure
      Thread.current[:origin_type] = nil
    end
  end

  private

  def current_year_steps
    @current_year_steps ||= begin
      steps = steps_fetcher.steps if current_user_classroom.present?
      year = current_school_year || current_school_calendar.year
      steps ||= SchoolCalendar.find_by(unity_id: current_unity.id, year: year).steps
      steps
    end
  end

  def first_step_start_date_for_posting
    current_year_steps.first.start_date_for_posting
  end

  def last_step_end_date_for_posting
    current_year_steps.last.end_date_for_posting
  end

  def set_honeybadger_context
    if (request.path || '').include?('api/v2')
      classroom_id = params[:classroom_id]
      teacher_id = params[:teacher_id]
      discipline_id = params[:discipline_id]
    else
      classroom_id = current_user_classroom.try(:id)
      teacher_id = current_teacher.try(:id)
      discipline_id = current_user_discipline.try(:id)
    end

    Honeybadger.context(
      entity: current_entity.try(:name),
      current_classroom_id: classroom_id,
      current_teacher_id: teacher_id,
      current_discipline_id: discipline_id,
      current_unity_id: current_unity.try(:id),
      current_year: current_school_year
    )
  end

  def send_pdf(prefix, pdf_to_s)
    name = report_name(prefix)
    File.open("#{Rails.root}/public#{name}", 'wb') do |f|
      f.write(pdf_to_s)
    end
    redirect_to name
  end

  def report_name(prefix)
    "/relatorios/#{prefix}-#{SecureRandom.hex}.pdf"
  end

end
