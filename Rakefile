require 'rubygems'

require 'merb-core'
require 'merb-core/tasks/merb'

include FileUtils

# Load the basic runtime dependencies; this will include
# any plugins and therefore plugin rake tasks.
init_env = ENV['MERB_ENV'] || 'rake'
Merb.load_dependencies(:environment => init_env)

# Get Merb plugins and dependencies

# Some vendored Merb plugins ship rake tasks written against RSpec 1 — notably
# merb-auth-slice-password/spectasks.rb, which requires 'spec/rake/spectask'.
# RSpec 3 does not provide that file, and because a raise here happens at load
# time it used to abort *every* rake task, db:migrate included. Skip the
# rakefiles that cannot load instead of taking the whole Rakefile down.
Merb::Plugins.rakefiles.each do |r|
  begin
    require r
  rescue LoadError, NameError => e
    warn "Skipping Merb plugin rakefile #{r} (#{e.class}: #{e.message})"
  end
end

# Load any app level custom rakefile extensions from lib/tasks
tasks_path = File.join(File.dirname(__FILE__), "lib", "tasks")
rake_files = Dir["#{tasks_path}/*.rake"]
rake_files.each{|rake_file| load rake_file }

desc "add folder step definitions"
task :add_folder_step_definitions do
  `mkdir -p features/step_definitions`
  chdir "features/step_definitions"
  `ls -d ../*/steps`.split("\n").each do |path|
    pp = path.split '/';
    puts `ln -s #{path} #{pp[1]}_steps`
  end
end
