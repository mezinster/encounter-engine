# -*- encoding : utf-8 -*-
module FixturesHelper
  # Returns a value unique within the process, not merely unlikely to repeat.
  # rand(1000000) alone was a birthday-paradox collision waiting to happen:
  # create_user derives both nickname and email from this, both are unique
  # columns, and the database is rebuilt once per suite rather than per
  # example, so every user from every example shares one table. A few hundred
  # rows against a 10^6 space fails a few runs in a hundred -- rarely enough
  # to look like a fluke, often enough to break CI.
  def self.next_sequence_number
    @sequence_number = (@sequence_number || 0) + 1
  end

  def random_string
    "#{FixturesHelper.next_sequence_number}#{rand(1000000)}"
  end

  def create_user
    random_nickname = "valid" + random_string
    random_email = random_nickname + "@diesel.kg"

    User.create! :nickname => random_nickname, :email => random_email, :password => "1234",
      :password_confirmation => "1234"
  end

  def create_team(options={})
    random_name = "Team#" + random_string
    team = Team.new(:name => random_name, :captain => options[:captain])
    team.members << options[:members] unless options[:members].nil?
    team.save!
    team
  end

  def create_invitation(options={})
    for_user = options[:for] || create_user
    from_team = options[:from] || create_team(:captain => create_user)
    Invitation.create! :to_team => from_team, :recepient_nickname => for_user.nickname
  end

  def build_game(options={})
    creation_params = {
      :author => create_user,
      :name => random_string,
      :description => random_string,
      :starts_at => "2099-01-01 00:00",
      :max_team_number => 100
    }.merge(options)
    Game.new creation_params
  end

  def create_game(options={})
    game = build_game(options)
    game.save!
    game
  end

  def build_level(options={})
    params = {
      :name => 'Test level',
      :text => "Some text",
      :correct_answer => random_string,
      :game => create_game
    }.merge(options)
    Level.new(params)
  end

  def create_level(options={})
    level = build_level(options)
    level.save!
    level
  end

  def create_question(options={})
    creation_params = {
      :correct_answer => random_string
    }.merge(options)

    question = Question.new creation_params
    question.save!
    question
  end

  def create_game_passing(options={})
    current_level = options.delete(:level) || create_level
    game = current_level.game
    
    creation_params = {
      :game => game,
      :current_level => current_level,
      :team => create_team
    }.merge(options)
    
    GamePassing.create! creation_params
  end

  def create_option(options={})
    creation_params = {
      :text => random_string,
      :is_correct => false
    }.merge(options)

    Option.create! creation_params
  end

  def create_hint(options={})
    creation_params = {
      :level => create_level,
      :text => 'Test hint',
      :delay => rand(60) * 60
    }.merge(options)

    Hint.create! creation_params
  end
end
