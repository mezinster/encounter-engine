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
      delivered = MailDelivery.attempt do
        NotificationMailer.invitation_notification(@invitation.for_user, @invitation.to_team).deliver_now
      end

      # Unlike password reset, there is no oracle to protect here: the captain
      # already knows who they invited. Silence would just leave them waiting
      # for a reply to a message that was never sent.
      #
      # alert:, not notice:, on the unnotified branch -- components.css gives
      # .flash--alert a danger border and .flash--notice a neutral one, and
      # #accept/#reject already warn in red for this same class of failure.
      # Warning in grey here was the odd one out among the four invitation
      # sites, not a deliberate distinction.
      if delivered
        redirect_to new_invitation_path,
                    notice: t("invitations.notice_sent", nickname: @invitation.recepient_nickname)
      else
        redirect_to new_invitation_path,
                    alert: t("invitations.notice_sent_unnotified", nickname: @invitation.recepient_nickname)
      end
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
    delivered = MailDelivery.attempt do
      NotificationMailer.accept_notification(@invitation.for_user, @invitation.to_team).deliver_now
    end

    # `&`, not `&&`: this must NOT short-circuit. Before MailDelivery existed a
    # raise on the line above skipped this call entirely, leaving the join done
    # and every other captain holding a stale invitation, un-notified.
    delivered &= reject_rest_of_invitations

    # One flash for both mail operations, never one per failed recipient.
    if delivered
      redirect_to dashboard_path
    else
      redirect_to dashboard_path, alert: t("invitations.accept_unnotified")
    end
  end

  def reject
    @invitation.delete
    # Merb original: app/controllers/invitations.rb#send_reject_notification.
    delivered = MailDelivery.attempt do
      NotificationMailer.reject_notification(@invitation.for_user, @invitation.to_team).deliver_now
    end

    if delivered
      redirect_to dashboard_path
    else
      redirect_to dashboard_path, alert: t("invitations.reject_unnotified")
    end
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
    all_delivered = true

    Invitation.for(current_user).each do |invitation|
      invitation.delete
      # `&=` so one captain's failed notification never stops the loop: the
      # invitations are deleted either way, and the caller reports a single
      # summary rather than one flash per recipient.
      all_delivered &= MailDelivery.attempt do
        NotificationMailer.reject_notification(invitation.for_user, invitation.to_team).deliver_now
      end
    end

    all_delivered
  end
end
