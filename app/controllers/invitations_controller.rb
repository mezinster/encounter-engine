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
      # Merb original: app/controllers/invitations.rb#send_invitation_notification.
      NotificationMailer.invitation_notification(@invitation.for_user, @invitation.to_team).deliver_now
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

    # Merb original: app/controllers/invitations.rb#send_accept_notification.
    # @invitation.delete only removes the DB row -- the in-memory object and
    # its already-resolved for_user/to_team associations are still valid.
    NotificationMailer.accept_notification(@invitation.for_user, @invitation.to_team).deliver_now

    reject_rest_of_invitations

    redirect_to dashboard_path
  end

  def reject
    @invitation.delete
    # Merb original: app/controllers/invitations.rb#send_reject_notification.
    NotificationMailer.reject_notification(@invitation.for_user, @invitation.to_team).deliver_now
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

  # Merb original: app/controllers/invitations.rb#reject_rest_of_invitations.
  # When a user accepts one invitation, every other pending invitation to
  # them is auto-rejected -- and each of those captains gets the same
  # reject_notification a manual #reject would have sent them.
  def reject_rest_of_invitations
    Invitation.for(current_user).each do |invitation|
      invitation.delete
      NotificationMailer.reject_notification(invitation.for_user, invitation.to_team).deliver_now
    end
  end
end
