require 'appear/service'
require 'appear/util/command_builder'
require 'appear/util/value_class'

module Appear
  # The Tmux service is in charge of interacting with `tmux` processes. It is
  # used by the Tmux revealer, but could also be used as the building block for
  # other tmux-related scripts.
  #
  # see the man page for tmux if you are curious about what clients, windows,
  # panes, and sessions are in Tmux world.
  class Tmux < Service
    delegate :run, :runner

    # Base value class for Tmux values. This class works in concert with the
    # Tmux service to make a fluent Tmux API easy.
    #
    # TmuxValues all have a reference to the Tmux service that created them, so
    # that they can implement methods that proxy Tmux service interaction.
    class TmuxValue < ::Appear::Util::ValueClass
      # @return [Tmux] the tmux service that created this pane
      property :tmux

      # @option opts [Symbol] :tmux tmux format string name of this attribute
      # @option opts [#to_proc] :parse proc taking a String (read from tmux) and
      # returns the type-coerced version of this field. A symbol can be used,
      # just like with usual block syntax.
      def self.property(name, opts = {})
        var = super(name, opts)
        @tmux_attrs ||= {}
        @tmux_attrs[var] = opts if opts[:tmux]
      end

      # The format string we pass to Tmux when we expect a result of this
      # class's type. This format string should cause Tmux to return a value we
      # can hand to {self.parse}
      #
      # @return [String]
      def self.format_string
        result = ""
        @tmux_attrs.each do |var, opts|
          next unless opts[:tmux]
          part = ' ' + var.to_s + ':#{' + opts[:tmux].to_s + '}'
          result += part
        end
        result
      end

      # Parse a raw data has as returned by the {Tmux} service into an instance
      # of this class.
      #
      # @param tmux_hash [Hash]
      # @param tmux [Tmux] the tmux service
      def self.parse(tmux_hash, tmux)
        result = { :tmux => tmux }
        tmux_hash.each do |var, tmux_val|
          parser = @tmux_attrs[var][:parse]
          if parser
            result[var] = parser.to_proc.call(tmux_val)
          else
            result[var] = tmux_val
          end
        end
        self.new(result)
      end
    end

    # A tmux pane.
    class Pane < TmuxValue
      # @return [Fixnum] pid of the process running in the pane
      property :pid, tmux: :pane_pid, parse: :to_i

      # @return [String] session name
      property :session, tmux: :session_name

      # @return [Fixnum] window index
      property :window, tmux: :window_index, parse: :to_i

      # @return [Fixnum] pane index
      property :pane, tmux: :pane_index, parse: :to_i

      # @return [Boolean] is this pane the active pane in this session
      property :active?, var: :active, tmux: :pane_active, parse: proc {|a| a.to_i != 0 }

      # @return [String] command running in this pane
      property :command_name, tmux: :pane_current_command

      # @return [String] pane current path
      property :current_path, tmux: :pane_current_path

      # @return [String] window id
      property :id, :tmux => :pane_id

      # String suitable for use as the "target" specifier for a Tmux command
      #
      # @return [String]
      def target
        # "#{session}:#{window}.#{pane}"
        id
      end

      # Split this pane
      #
      # @param opts [Hash]
      def split(opts = {})
        tmux.split_window(opts.merge(:t => target))
      end

      # Reveal this pane
      def reveal
        tmux.reveal_pane(self)
      end

      # Send keys to this pane
      #
      # @param keys [String]
      # @param opts [Hash]
      def send_keys(keys, opts = {})
        tmux.send_keys(self, keys, opts)
      end
    end

    # A tmux session.
    # Has many windows.
    class Session < TmuxValue
      # @return [String] session name
      property :session, tmux: :session_name

      # @return [String] tmux id of this session
      property :id, :tmux => :session_id

      # @return [Fixnum] number of clients attached to this session
      property :attached, :tmux => :session_attached, :parse => :to_i

      # @return [Fixnum] width, in text columns
      property :width, :tmux => :session_width, :parse => :to_i

      # @return [Fixnum] height, in text rows
      property :height, :tmux => :session_height, :parse => :to_i

      # String suitable for use as the "target" specifier for a Tmux command
      #
      # @return [String]
      def target
        # session
        id
      end

      # @return [Array<Window>] the windows in this session
      def windows
        tmux.windows.select { |w| w.session == session }
      end

      # @return [Array<Client>] all clients attached to this session
      def clients
        tmux.clients.select { |c| c.session == session }
      end

      # Create a new window in this session. By default, the window will be
      # created at the end of the session.
      #
      # @param opts [Hash]
      def new_window(opts = {})
        win = windows.last.window || -1
        tmux.new_window(opts.merge(:t => "#{target}:#{win + 1}"))
      end
    end

    # A tmux window.
    # Has many panes.
    class Window < TmuxValue
      # @return [String] session name
      property :session, :tmux => :session_name

      # @return [Fixnum] window index
      property :window, :tmux => :window_index, :parse => :to_i

      # @return [String] window id
      property :id, :tmux => :window_id

      # @return [Boolean] is the window active?
      property :active?,
        :tmux => :window_active,
        :var => :active,
        :parse => proc {|b| b.to_i != 0}

      # @return [Array<Pane>]
      def panes
        tmux.panes.select { |p| p.session == session && p.window == window }
      end

      # String suitable for use as the "target" specifier for a Tmux command
      #
      # @return [String]
      def target
        # "#{session}:#{window}"
        id
      end
    end

    # A tmux client.
    class Client < TmuxValue
      # @return [String] path to the TTY device of this client
      property :tty, :tmux => :client_tty

      # @return [String] term name
      property :term, :tmux => :client_termname

      # @return [String] session name
      property :session, :tmux => :client_session

      # String suitable for use as the "target" specifier for a Tmux command
      #
      # @return [String]
      def target
        tty
      end
    end

    def initialize(svcs = {})
      super(svcs)
      @memo = ::Appear::Util::Memoizer.new
    end

    # List all the tmux clients on the system
    #
    # @return [Array<Client>]
    def clients
      ipc_returning(command('list-clients'), Client)
    end

    # List all the tmux panes on the system
    #
    # @return [Array<Pane>]
    def panes
      ipc_returning(command('list-panes').flags(:a => true), Pane)
    end

    # List all the tmux sessions on the system
    #
    # @return [Array<Session>]
    def sessions
      ipc_returning(command('list-sessions'), Session)
    end

    # List all the tmux windows in any session on the system
    #
    # @return [Array<Window>]
    def windows
      ipc_returning(command('list-windows').flags(:a => true), Window)
    end

    # Reveal a pane in tmux.
    #
    # @param pane [Pane] a pane
    def reveal_pane(pane)
      ipc(command('select-pane').flags(:t => pane.target))
      # TODO: how do we use a real target for this?
      ipc(command('select-window').flags(:t => "#{pane.session}:#{pane.window}"))
      pane
    end

    # Create a new window
    def new_window(opts = {})
      ipc_returning_one(command('new-window').flags(opts), Window)
    end

    # Split a window
    def split_window(opts = {})
      ipc_returning_one(command('split-window').flags(opts), Pane)
    end

    # Create a new session
    def new_session(opts = {})
      ipc_returning_one(command('new-session').flags(opts), Session)
    end

    # Send keys to a pane
    def send_keys(pane, keys, opts = {})
      ipc(command('send-keys').flags(opts.merge(:t => pane.target)).args(*keys))
    end

    # Construct a command that will attach the given session when run
    #
    # @param session [String] use Session#target
    # @return [Appear::Util::CommandBuilder]
    def attach_session_command(session)
      command('attach-session').flags(:t => session)
    end

    private

    def command(subcommand)
      Appear::Util::CommandBuilder.new(['tmux', subcommand])
    end

    def ipc(cmd)
      res = run(cmd.to_a)
      res.lines.map do |line|
        info = {}
        line.strip.split(' ').each do |pair|
          key, *value = pair.split(':')
          info[key.to_sym] = value.join(':')
        end
        info
      end
    end

    def ipc_returning(cmd, klass)
      @memo.call(cmd, klass) do
        cmd.flags(:F => klass.format_string)
        ipc(cmd).map do |row|
          klass.parse(row, self)
        end
      end
    end

    def ipc_returning_one(cmd, klass)
      # -P in tmux is usually required to print information about newly created objects
      ipc_returning(cmd.flags(:P => true), klass).first
    end
  end
end
