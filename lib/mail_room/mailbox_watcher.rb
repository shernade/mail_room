require "mail_room/connection"

module MailRoom
  # TODO: split up between processing and idling?

  # Watch a Mailbox
  # @author Tony Pitale
  class MailboxWatcher
    attr_accessor :watching_thread

    # Watch a new mailbox
    # @param mailbox [MailRoom::Mailbox] the mailbox to watch
    def initialize(mailbox)
      @mailbox = mailbox

      @running = false
      @connection = nil
    end

    # are we running?
    # @return [Boolean]
    def running?
      @running
    end

    # run the mailbox watcher
    def run
      @mailbox.logger.info({ context: @mailbox.context, action: "Setting up watcher" })
      @running = true

      connection.on_new_message do |message|
        delivered = @mailbox.deliver(message)
        puts "delivered"
        puts delivered

        puts "@mailbox.move_after_delivery && delivered"
        puts @mailbox.move_after_delivery && delivered
        connection.move(message) if @mailbox.move_after_delivery && delivered
      end

      self.watching_thread = Thread.start do
        while(running?) do
          connection.wait
        end
      end

      watching_thread.abort_on_exception = true
    end

    # stop running, cleanup connection
    def quit
      @mailbox.logger.info({ context: @mailbox.context, action: "Quitting connection..." })
      @running = false

      if @connection
        @connection.quit
        @connection = nil
      end

      if self.watching_thread
        self.watching_thread.join
      end
    end

    private

    def connection
      @connection ||=
        if @mailbox.microsoft_graph?
          ::MailRoom::MicrosoftGraph::Connection.new(@mailbox)
        else
          ::MailRoom::IMAP::Connection.new(@mailbox)
        end
    end
  end
end
