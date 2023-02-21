# frozen_string_literal: true

module MailRoom
  module IMAP
    class Connection < MailRoom::Connection
      def initialize(mailbox)
        super

        # log in and set the mailbox
        reset
        setup
      end

      # is the connection logged in?
      # @return [Boolean]
      def logged_in?
        @logged_in
      end

      # is the connection blocked idling?
      # @return [Boolean]
      def idling?
        @idling
      end

      # is the imap connection closed?
      # @return [Boolean]
      def disconnected?
        imap.disconnected?
      end

      # is the connection ready to idle?
      # @return [Boolean]
      def ready_to_idle?
        logged_in? && !idling?
      end

      def quit
        stop_idling
        reset
      end

      def wait
        # in case we missed any between idles
        process_mailbox

        idle

        process_mailbox
      rescue Net::IMAP::Error, IOError => e
        @mailbox.logger.warn({ context: @mailbox.context, action: 'Disconnected. Resetting...', error: e.message })
        reset
        setup
      end

      def move(message)
        puts "moving"
        puts message.uid
        if !imap.list('Appmanager/', mailbox.stage)
          @mailbox.logger.info({ context: @mailbox.context, action: "Creating folder Appmanager/#{mailbox.stage}" })
          imap.create("Appmanager/#{mailbox.stage}")
        end
        @mailbox.logger.info({ context: @mailbox.context, action: "Moving msg to folder Appmanager/#{mailbox.stage}" })
        puts "jejejej"
        a = imap.move(message.uid, "Appmanager/#{mailbox.stage}")
        puts a
        a
      end

      private

      def reset
        @imap = nil
        @logged_in = false
        @idling = false
      end

      def setup
        @mailbox.logger.info({ context: @mailbox.context, action: 'Starting TLS session' })
        start_tls

        @mailbox.logger.info({ context: @mailbox.context, action: 'Logging into mailbox' })
        log_in

        @mailbox.logger.info({ context: @mailbox.context, action: 'Setting mailbox' })
        set_mailbox
      end

      # build a net/imap connection to google imap
      def imap
        @imap ||= Net::IMAP.new(@mailbox.host, port: @mailbox.port, ssl: @mailbox.ssl_options)
      end

      # start a TLS session
      def start_tls
        imap.starttls if @mailbox.start_tls
      end

      # send the imap login command to google
      def log_in
        imap.login(@mailbox.email, @mailbox.password)
        @logged_in = true
      end

      # select the mailbox name we want to use
      def set_mailbox
        imap.select(@mailbox.name) if logged_in?
      end

      # is the response for a new message?
      # @param response [Net::IMAP::TaggedResponse] the imap response from idle
      # @return [Boolean]
      def message_exists?(response)
        response.respond_to?(:name) && response.name == 'EXISTS'
      end

      # @private
      def idle_handler
        ->(response) { imap.idle_done if message_exists?(response) }
      end

      # maintain an imap idle connection
      def idle
        return unless ready_to_idle?

        @mailbox.logger.info({ context: @mailbox.context, action: 'Idling' })
        @idling = true

        imap.idle(@mailbox.idle_timeout, &idle_handler)
      ensure
        @idling = false
      end

      # trigger the idle to finish and wait for the thread to finish
      def stop_idling
        return unless idling?

        imap.idle_done

        # idling_thread.join
        # self.idling_thread = nil
      end

      def process_mailbox
        return unless @new_message_handler

        @mailbox.logger.info({ context: @mailbox.context, action: 'Processing started' })

        msgs = new_messages
        any_deletions = msgs.
                        # deliver each new message, collect success
                        map(&@new_message_handler).
                        # include messages with success
                        zip(msgs).
                        # filter failed deliveries, collect message
                        select(&:first).map(&:last).
                        # after delivered messages
                        map { |message| after_delivery(message) }
                            .any?

        imap.expunge if @mailbox.expunge_deleted && any_deletions
      end

      def after_delivery(message)
        if @mailbox.delete_after_delivery
          imap.store(message.seqno, '+FLAGS', [Net::IMAP::DELETED])
          true
        end
      end

      # @private
      # fetch all messages for the new message ids
      def new_messages
        # Both of these calls may results in
        #   imap raising an EOFError, we handle
        #   this exception in the watcher
        messages_for_ids(new_message_ids)
      end

      # TODO: label messages?
      #   @imap.store(id, "+X-GM-LABELS", [label])

      # @private
      # search for all new (unseen) message ids
      # @return [Array<Integer>] message ids
      def new_message_ids
        # uid_search still leaves messages UNSEEN
        all_unread = imap.uid_search(@mailbox.search_command)

        all_unread = all_unread.slice(0, @mailbox.limit_max_unread) if @mailbox.limit_max_unread.to_i > 0

        to_deliver = all_unread.select { |uid| @mailbox.deliver?(uid) }
        @mailbox.logger.info({ context: @mailbox.context, action: 'Getting new messages',
                               unread: { count: all_unread.count, ids: all_unread }, to_be_delivered: { count: to_deliver.count, ids: to_deliver } })
        to_deliver
      end

      # @private
      # fetch the email for all given ids in RFC822 format
      # @param ids [Array<Integer>] list of message ids
      # @return [Array<MailRoom::IMAP::Message>] the net/imap messages for the given ids
      def messages_for_ids(uids)
        return [] if uids.empty?

        # uid_fetch marks as SEEN, will not be re-fetched for UNSEEN
        imap_messages = imap.uid_fetch(uids, 'RFC822')

        imap_messages.each_with_object([]) do |msg, messages|
          messages << ::MailRoom::IMAP::Message.new(uid: msg.attr['UID'], body: msg.attr['RFC822'], seqno: msg.seqno)
        end
      end
    end
  end
end
