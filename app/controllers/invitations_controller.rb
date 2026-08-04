# -*- encoding : utf-8 -*-
class InvitationsController < ApplicationController
  include SecurityFilters

  before_action :require_authentication!
  before_action :ensure_team_captain, only: [:new, :create]
  before_action :find_invitation, only: [:accept, :reject]
  before_action :ensure_recepient, only: [:accept, :reject]

  def new
    @invitation = Invitation.new(to_team: current_user.team)
    @all_users = User.all
  end

  def create
    @invitation = Invitation.new(invitation_params)
    @invitation.to_team = current_user.team

    if @invitation.save
      # TODO(Task 10): app/mailers/notification_mailer.rb is still the
      # pre-port Merb::MailController and cannot be referenced from Rails
      # yet (referencing the constant raises NameError: uninitialized
      # constant Merb, since nothing in the Rails boot defines it). The
      # Merb original sent an "invitation_notification" email here; restore
      # that call once Task 10 ports NotificationMailer to ActionMailer.
      redirect_to new_invitation_path,
                  notice: t("invitations.notice_sent", nickname: @invitation.recepient_nickname)
    else
      @all_users = User.all
      render :new, status: :unprocessable_entity
    end
  end

  def accept
    add_user_to_team_members
    @invitation.delete

    # TODO(Task 10): send_accept_notification -- see the NotificationMailer
    # note in #create above.
    reject_rest_of_invitations

    redirect_to dashboard_path
  end

  def reject
    @invitation.delete
    # TODO(Task 10): send_reject_notification -- see the NotificationMailer
    # note in #create above.
    redirect_to dashboard_path
  end

  private

  def invitation_params
    params.fetch(:invitation, ActionController::Parameters.new).permit(:recepient_nickname)
  end

  def find_invitation
    @invitation = Invitation.find(params[:id])
  end

  def ensure_recepient
    raise Authentication::Unauthorized, t("errors.must_be_recipient") unless current_user.id == @invitation.for_user.id
  end

  def add_user_to_team_members
    @invitation.to_team.members << current_user
  end

  # TODO(Task 10): each rejection here used to email the invited user too
  # (send_reject_notification); deferred along with the rest of the mailer
  # calls in this controller.
  def reject_rest_of_invitations
    Invitation.for(current_user).each(&:delete)
  end
end
