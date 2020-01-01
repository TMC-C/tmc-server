# frozen_string_literal: true

require 'spyware_client'

# Presents the "register user" and "edit profile" views.
class UsersController < ApplicationController
  skip_authorization_check

  after_action :remove_x_frame_options_header_when_bare_layout, only: %i[new create show]

  def index
    raise CanCan::AccessDenied if current_user.guest?
    respond_access_denied unless current_user.administrator?
    @users = User.search(params[:search])
  end

  def new
    authorize! :create, User
    alternative_location = SiteSetting.all_settings["signup_location"]
    return redirect_to alternative_location if alternative_location
    add_breadcrumb 'Sign up', new_user_path

    if signed_in?
      # Logged in from this page. No need to be here, so redirect away
      redirect_to root_path
    else
      @user = User.new
    end
  end

  def create
    authorize! :create, User

    @user = User.new

    @user.login = params[:user][:login].to_s.strip

    set_email
    set_password
    set_user_fields

    if @user.errors.empty? && @user.save
      UserMailer.email_confirmation(@user).deliver_now
      if @bare_layout
        render text: '<div class="success" style="font-size: 14pt; margin: 10pt;">User account created.</div>', layout: true
      else
        flash[:notice] = 'User account created. You can now log in.'
        redirect_to root_path
      end
    else
      render action: :new, status: :forbidden
    end
  end

  def show
    add_breadcrumb 'My account', user_path

    if current_user.guest?
      raise CanCan::AccessDenied
    else
      @user = current_user
    end
  end

  def update
    @user = current_user

    set_email
    password_changed = maybe_update_password(@user, params[:user])
    user_field_changes = set_user_fields

    begin
      log_user_field_changes(user_field_changes)
    rescue StandardError
    end

    if @user.errors.empty? && @user.save
      flash[:notice] = if password_changed
        'Changes saved and password changed'
      else
        'Changes saved'
      end
      redirect_to user_path
    else
      flash.now[:error] = 'Failed to save profile'
      render action: :show, status: :forbidden
    end
  end

  def confirm_email
    language = params[:language]
    token = VerificationToken.unscoped.email.find_by!(user_id: params[:user_id], token: params[:id])
    redirect_path = root_url
    redirect_path = "https://course.elementsofai.com/#{language ? "#{language}/" : ''}email-verification" if params[:origin] && params[:origin].start_with?('elements_of_ai')
    User.find(params[:user_id]).update!(email_verified: true)
    redirect_to redirect_path, notice: 'Your email address has been verified!'
  end

  def send_verification_email
    user = User.find(params[:user_id])
    raise 'Access denied' if user != current_user && !current_user.admin?
    raise 'Already verified' if user.email_verified?
    UserMailer.email_confirmation(user).deliver_now
    redirect_to root_path, notice: "Verification email sent to #{user.email}."
  end

  def verify_destroying_user
    @user = authenticate_current_user_destroy
    token = VerificationToken.delete_user.find_by!(user: @user, token: params[:id])
  end

  def destroy_user
    im_sure = params[:im_sure]
    if im_sure != '1'
      redirect_to verify_destroying_user_url, notice: 'Please check the checkbox after you have read the instructions.'
      return
    end
    user = authenticate_current_user_destroy
    user_authentication = User.authenticate(user.login, params[:user][:password])
    if user_authentication.nil?
      redirect_to verify_destroying_user_url, alert: 'The password was incorrect.'
      return
    end
    token = VerificationToken.delete_user.find_by!(user: user, token: params[:id])
    username = user.login
    sign_out if current_user == user
    email = user.email
    username = user.login
    user.destroy
    RecentlyChangedUserDetail.deleted.create!(old_value: false, new_value: true, email: email, username: username)
    redirect_to root_url, notice: 'Your account has been permanently destroyed.'
  end

  def send_destroy_email
    user = authenticate_current_user_destroy
    UserMailer.destroy_confirmation(user).deliver_now
    redirect_to root_path, notice: "Verification email sent to #{user.email}."
  end

  private

    def authenticate_current_user_destroy
      user = User.find(params[:user_id])
      authorize! :destroy, user
      user
    end

    def set_email
      user_params = params[:user]

      return if !@user.new_record? && user_params[:email_repeat].blank?

      if user_params[:email].blank?
        @user.errors.add(:email, 'needed')
      elsif user_params[:email] != user_params[:email_repeat]
        @user.errors.add(:email_repeat, 'did not match')
      else
        @user.email = user_params[:email].strip
      end
    end

    def set_password
      user_params = params[:user]
      if user_params[:password].blank?
        @user.errors.add(:password, 'needed')
      elsif user_params[:password] != user_params[:password_repeat]
        @user.errors.add(:password_repeat, 'did not match')
      else
        @user.password = user_params[:password]
      end
    end

    def maybe_update_password(user, user_params)
      if user_params[:old_password].present? || user_params[:password].present?
        if !user.has_password?(user_params[:old_password])
          user.errors.add(:old_password, 'incorrect')
        elsif user_params[:password] != user_params[:password_repeat]
          user.errors.add(:password_repeat, 'did not match')
        elsif user_params[:password].blank?
          user.errors.add(:password, 'cannot be empty')
        else
          user.password = user_params[:password]
        end
        true
      else
        false
      end
    end

    def set_user_fields
      return if params[:user_field].nil?
      changes = {}
      UserField.all.select { |f| f.visible_to?(current_user) }.each do |field|
        value_record = @user.field_value_record(field)
        old_value = value_record.ruby_value
        value_record.set_from_form(params[:user_field][field.name])
        new_value = value_record.ruby_value
        changes[field.name] = { from: old_value, to: new_value } unless new_value == old_value
      end
      changes
    end

    def log_user_field_changes(changes)
      unless changes.empty?
        data = {
          eventType: 'user_fields_changed',
          changes: changes.clone,
          happenedAt: (Time.now.to_f * 1000).to_i
        }
        Thread.new do
          SpywareClient.send_data_to_any(data.to_json, current_user.username, request.session_options[:id])
        rescue StandardError
          logger.warn('Failed to send user field changes to spyware: ' + $!.message + "\n " + $!.backtrace.join("\n "))
        end
      end
    end
end
