module Seek
  module Git
    # A class to wrap ruby-git operations, in order to make testing easier.
    # Maybe we can remove this at some point if we figure out how to make git operations use VCR.
    class Base
      delegate :lookup, :write, :empty?, :head, :ref, :add_remote, :index, :remotes, :fetch, :head_unborn?, to: :@git_base

      def initialize(path)
        @git_base = Rugged::Repository.new(path)
      end

      def base
        @git_base
      end

      def add_remote(name, url)
        @git_base.remotes.create(name, url)
      end

      def self.base_class
        Rails.env.test? ? Seek::Git::MockBase : self
      end

      # Rugged cannot do this without initializing a repo on disk, so use ruby git.
      def self.ls_remote(remote, ref = nil)
        ::Git.ls_remote(ref ? "#{remote} #{ref}" : remote)
      end

      def self.init(path)
        ::Rugged::Repository.init_at(path)
      end
    end
  end
end