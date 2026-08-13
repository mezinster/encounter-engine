# -*- encoding : utf-8 -*-
#
# The §4 authorization matrix from
# docs/superpowers/specs/2026-08-12-level-and-hint-attachments-design.md.
#
# A plain object rather than controller filters, for two reasons. It is the
# security contract, so it is worth testing without an HTTP round trip; and
# phase 3B's play screen needs the same answer BEFORE rendering, to decide
# whether a strip appears at all -- a view that renders <img> tags the
# delivery route will 404 is worse than one that renders nothing.
class GameFileAccess
  def initialize(user, game_file)
    @user = user
    @game_file = game_file
  end

  def permitted?
    return false if @user.nil? || @game_file.nil?
    return true  if author_or_superadmin?

    false
  end

  private

  def game = @game_file.game

  def author_or_superadmin?
    return false if game.nil?

    @user.superadmin? || @user.author_of?(game)
  end
end
