# -*- encoding : utf-8 -*-
class User < ActiveRecord::Base
  belongs_to :team

  has_many :created_games, :class_name => "Game", :foreign_key => "author_id"

  validates_presence_of :email, :message => "Не введён e-mail"

  # Restored from before d21a177 ("Upgrade to ActiveRecord 4.0"), which dropped
  # it along with the icq/jabber/phone format validations. Without it any string
  # is accepted as an address and the welcome letter goes nowhere.
  #
  # The dot in the domain group is escaped, which the original was not: an
  # unescaped . matches any character, so "user@localhost" passed by consuming
  # the final "t" as the separator. No address used anywhere in the suites is
  # affected by tightening it.
  validates_format_of :email, :with => /\A([^@\s]+)@((?:[-a-z0-9]+\.)+[a-z]{2,})\Z/i,
    :message => "Неправильный формат поля e-mail"

  validates_uniqueness_of :email,
    :message => "Пользователь с таким адресом уже зарегистрирован"

  validates_presence_of :nickname,
    :message => "Вы не ввели имя"

  validates_uniqueness_of :nickname,
    :message => "Пользователь с таким именем уже зарегистрирован"

  validates_length_of :password, :minimum => 4,
    :message => "Слишком короткий пароль (минимум 4 символа)",
    :if => :password_required?

  validates_confirmation_of :password,
    :message => "Пароль и его подтверждение не совпадают",
    :if => :password_required?


  def member_of_any_team?
    !! team
  end

  def captain?
    member_of_any_team? && team.captain.id == id
  end

  def author_of?(game)
    game.author.id == self.id
  end
end
