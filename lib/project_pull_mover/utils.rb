# typed: true
# frozen_string_literal: true
# encoding: utf-8

module ProjectPullMover
  module Utils
    extend T::Sig

    include Kernel

    sig { params(cmd: String).returns(T.nilable(String)) }
    def which(cmd)
      pathext = ENV['PATHEXT']
      exts = pathext ? pathext.split(';') : ['']
      path_env = ENV['PATH'] || ""
      path_env.split(File::PATH_SEPARATOR).each do |path|
        exts.each do |ext|
          exe = File.join(path, "#{cmd}#{ext}")
          return exe if File.executable?(exe) && !File.directory?(exe)
        end
      end
      nil
    end

    sig { params(str: String).returns(String) }
    def replace_hyphens(str)
      str.split("-").map(&:capitalize).join("")
    end
  end
end
