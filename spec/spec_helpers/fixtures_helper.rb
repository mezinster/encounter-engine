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

  def build_game_file(options={})
    params = {
      :game              => options[:game] || create_game,
      :filename          => "file#{random_string}.jpg",
      :content_type      => "image/jpeg",
      :byte_size         => 1024,
      :derived_byte_size => 0
    }.merge(options)
    GameFile.new params
  end

  def create_game_file(options={})
    game_file = build_game_file(options)
    game_file.save!
    game_file
  end

  # An uploaded file as Rack would hand it to a controller. content_type is
  # deliberately a LIE in some specs: the pipeline must sniff bytes and ignore
  # what the client claims.
  def fixture_upload(name, claimed_type = "application/octet-stream")
    Rack::Test::UploadedFile.new(
      Rails.root.join("spec/fixtures/files", name), claimed_type
    )
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

  # create_level always builds a code question via correct_answer. A quiz level
  # has none, so drop it -- otherwise every "quiz" spec silently tests a MIXED
  # level, which is a different thing.
  def create_quiz_level(options={})
    level = create_level(options)
    level.questions.destroy_all
    level.reload
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
      # Every passing belongs to a run. Defaulted here rather than at 85 call
      # sites; pass :game_run explicitly to place one in a different run, which
      # is what the isolation examples do.
      :game_run => game.current_run,
      :current_level => current_level,
      :team => create_team
    }.merge(options)

    GamePassing.create! creation_params
  end

  # A team plays a game only if its entry was accepted -- enforced in
  # GamePassingsController#find_or_create_game_passing. Specs that let the
  # controller create the passing (rather than pre-creating one with
  # create_game_passing) need the entry that authorises it.
  def create_game_entry(options={})
    game = options[:game]

    creation_params = {
      :status => "accepted"
    }.merge(options)

    # Admission belongs to a run, so an entry with no run authorises nothing.
    # Defaulted here rather than at every call site; pass :game_run explicitly
    # to place one in a different run, which is what the isolation examples do.
    creation_params[:game_run] ||= game.current_run if game

    GameEntry.create! creation_params
  end

  # The run must already be testing -- TestAdmission refuses otherwise -- so
  # this flips the flag rather than making every caller remember to. Pass
  # :user to build a SOLO admission; :team then names the disposable team.
  def create_test_admission(options={})
    run = options[:run] || create_game.current_run
    run.update_column(:is_testing, true) unless run.is_testing?

    TestAdmission.create!(:game_run => run,
                          :team     => options[:team] || create_team,
                          :user     => options[:user])
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

  # Arranges a game's SCHEDULE in a spec.
  #
  # Specs reach for update_column here because a running or finished game
  # cannot pass its own validations (game_starts_in_the_future fires whenever
  # author_finished_at is nil and starts_at is past), so an ordinary save would
  # raise on exactly the states these specs need to arrange.
  #
  # Writes the RUN only. It briefly wrote the games columns too, so that its 58
  # call sites were correct on both sides of the delegation switch; that write
  # is gone, and the suite passing without it is the proof that nothing reads
  # those columns any more -- which is what deploy 2 needs before it can drop
  # them.
  #
  # Only the EIGHT MOVING COLUMNS belong here. withdrawn_at and
  # editing_locked_at stay on games -- keep using update_column for those.
  # A SECOND run on a game. Nothing in the application can create one until
  # phase 3, and every isolation example in phase 2 needs one: with a single
  # run every run-scoped query returns exactly what the game-scoped one
  # returned, so an example without this would pass whether the scoping worked
  # or not.
  def create_next_run(game, attrs = {})
    GameRun.create!({ :game => game,
                      :ordinal => game.runs.reload.maximum(:ordinal).to_i + 1,
                      :starts_at => game.starts_at,
                      :max_team_number => game.max_team_number }.merge(attrs))
  end

  # A log row, with its run filled in from the game. Specs wrote Log.create!
  # by hand in 23 places; routing them through here is what let phase 2 add
  # game_run_id without editing all of them again when the log screens became
  # run-scoped.
  def create_log(attrs = {})
    game  = attrs[:game]  || create_game
    level = attrs[:level] || create_level(:game => game)
    team  = attrs[:team]  || create_team(:captain => create_user)

    Log.create!(:game_id     => game.id,
                :game_run_id => (attrs[:game_run] || game.current_run).id,
                :level       => attrs[:level_name] || level.name,
                :level_id    => attrs.key?(:level_id) ? attrs[:level_id] : level.id,
                :team        => attrs[:team_name] || team.name,
                :team_id     => attrs.key?(:team_id) ? attrs[:team_id] : team.id,
                :time        => attrs[:time] || Time.now,
                :answer      => attrs[:answer] || "код")
  end

  def set_game_schedule!(game, attrs)
    # The CURRENT run -- highest ordinal -- not runs.first. Those are the same
    # record until a game has a second run, and different the moment it does:
    # writing to runs.first would then schedule the run nobody is playing and
    # leave the current one untouched, which reads as a mysterious 401 from
    # ensure_game_is_started.
    run = game.runs.reload.to_a.last || game.runs.create!(:ordinal => 1)
    attrs.each { |column, value| run.update_column(column, value) }

    game
  end
end
