# Copyright 2010-2016, Raphael Reitzig
# <code@verrech.net>
#
# This file is part of ltx2any.
#
# ltx2any is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# ltx2any is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with ltx2any. If not, see <http://www.gnu.org/licenses/>.

require 'singleton'

DependencyManager.add("listen", :gem, :recommended,
                      "for daemon mode", ">=2.2.0") # 3.0.6

ParameterManager.instance.addParameter(Parameter.new(
  :daemon, "d", Boolean, false, "Re-compile automatically when files change."))
ParameterManager.instance.addParameter(Parameter.new(
  :listeninterval, "di", Float, 0.5,
  "Time after which daemon mode checks for changes (in seconds)."))

class FileListener
  include Singleton

  private

  def ignoreFileName(jobname)
    ".#{NAME}ignore_#{jobname}"
  end

  public

  def initialize
    @ignore = []
    ParameterManager.instance.addHook(:listeninterval) { |_,v|
      # TODO implement hook that catches changes to listen interval
    }
  end

  def ignored
    @ignore.clone
  end

  # Function that reads the ignorefile fo another process and
  # adds the contained files to the ignore list.
  def readIgnoreFile(ignoreFile)
    if ( File.exist?(ignoreFile) )
      IO.foreach(ignoreFile) { |line|
        @ignore.push(line.strip)
      }
    end
  end

  def start(jobname, ignores = [])
    # Make sure that the listen gem is available
    if !DependencyManager.available?("listen", :gem)
      raise MissingDependencyError.new("Daemon mode requires gem listen.")
    end
    params = ParameterManager.instance

    # Add the files to ignore from this process
    @ignore += ignores
    @ignorefile = ignoreFileName(jobname)
    @ignore.push(@ignorefile)

    # Write ignore list for other processes
    File.open("#{params[:jobpath]}/#{@ignorefile}", "w") { |file|
      file.write(@ignore.join("\n"))
    }

    # Collect all existing ignore files
    Dir.entries(".") \
      .select { |f| /(\.\/)?#{Regexp.escape(ignoreFileName(""))}[^\/]+/ =~ f } \
      .each { |f|
      readIgnoreFile(f)
    }


    # Setup daemon mode
    $vanishedfiles = []
      # Main listener: this one checks job files for changes and prompts recompilation.
      #                (indirectly: The Loop below checks $changetime.)
      $jobfilelistener =
        Listen.to('.',
                  latency: params[:listeninterval],
                  ignore: [ /(\.\/)?#{Regexp.escape(ignorefile)}[^\/]+/,
                            #/(\.\/)?\..*/, # ignore hidden files, e.g. .git
                            /\A(\.\/)?(#{$ignoredfiles.map { |s| Regexp.escape(s) }.join("|")})/ ],
                 ) \
        do |modified, added, removed|
          # TODO cruel hack; can we do better?
          removed.each { |r|
            $vanishedfiles.push File.path(r.to_s).sub(params[:jobpath], params[:tmpdir])
          }
          $changetime = Time.now
        end

      params.addHook(:listeninterval) { |key,val|
        # $jobfilelistener.latency = val
        # TODO tell change to listener; in worst case, restart?
      }

      # Secondary listener: this one checks for (new) ignore files, i.e. other
      #                     jobs in the same directory. It then updates the main
      #                     listener so that it does not react to changes in files
      #                     generated by the other process.
      $ignfilelistener =
        Listen.to('.',
                  #only: /\A(\.\/)?#{Regexp.escape(ignorefile)}[^\/]+/,
                  # TODO switch to `only` once listen 2.3 is available
                  ignore: /\A(?!(\.\/)?#{Regexp.escape(ignorefile)}).*/,
                  latency: 0.1
                 ) \
        do |modified, added, removed|
          $jobfilelistener.pause

          added.each { |ignf|
            files = ignoremore(ignf)
            $jobfilelistener.ignore(/\A(\.\/)?(#{files.map { |s| Regexp.escape(s) }.join("|")})/)
          }

          # TODO If another daemon terminates we keep its ignorefiles. Potential leak!
          #      If this turns out to be a problem, update list & listener (from scratch)

          $jobfilelistener.unpause
        end

      $ignfilelistener.start
      $changetime = Time.now
      $jobfilelistener.start
  end

  def waitForChanges
    OUTPUT.start("Waiting for file changes")
    files = Thread.new do
      while ( $changetime <= start_time || Time.now - $changetime < 2 )
        sleep(params[:listeninterval])
      end

      while ( Thread.current[:raisetarget] == nil ) do end
      Thread.current[:raisetarget].raise(Interrupt.new("Files have changed"))
    end
    files[:raisetarget] = Thread.current

    # Pause waiting if user wants to enter prompt
    begin
      STDIN.noecho(&:gets)
      files.kill
      OUTPUT.stop(:cancel)

      # Delegate. The method returns if the user
      # prompts a rerun. It throws a SystemExit
      # exception if the user wants to quit.
      DaemonPrompt.run(params)
    rescue Interrupt => e
      # We have file changes, rerun!
      OUTPUT.stop(:success)
    end

    # Remove files reported missing since last run from tmp (so we don't hide errors)
    # Be extra careful, we don't want to delete non-tmp files!
    $vanishedfiles.each { |f| FileUtils.rm_rf(f) if f.start_with?(PARAMS[:tmpdir]) && File.exists?(f) }
  end

  def pause
  end



  def stop
    begin
      $jobfilelistener.stop
      $ignfilelistener.stop
    rescue Exception
      # Apparently, stopping throws exceptions.
    end
  end




  # Removes temporary files outside of the tmp folder,
  # shuts down listener,
  # closes file handlers, etc.
  def cleanup
    FileUtils::rm_rf("#{params[:jobpath]}/#{ignorefile}#{params[:jobname]}")
  end

end
