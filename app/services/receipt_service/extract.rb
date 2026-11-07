# frozen_string_literal: true

module ReceiptService
  class Extract
    MODEL = "gpt-6-luna"

    SUPPORTED_IMAGE_TYPES = %w[image/png image/jpeg image/webp image/gif].freeze
    MAX_IMAGE_DIMENSION = 2048

    MAX_PDF_BYTES = 10.megabytes
    MAX_PDF_PAGES = 10

    attr_reader :best_match_hcb_code_id, :match_confidence

    def initialize(receipt:, candidates: [])
      @receipt = receipt.reload
      @candidates = candidates
    end

    def run!
      return @receipt if @receipt.data_extracted?

      # this line acts as a rate limit of sort.
      # see https://github.com/hackclub/hcb/issues/7167.
      return if @receipt.user.receipts.where(created_at: 1.hour.ago, data_extracted: true).count > 50 ||
                (@receipt.receiptable.present? && @receipt.receiptable.receipts.where(data_extracted: true).count > 5)

      content = file_content
      if content.nil?
        @receipt.update(data_extracted: true)
        return
      end

      conn = Faraday.new url: "https://api.openai.com" do |f|
        f.request :json
        f.request :authorization, "Bearer", -> { Credentials.fetch(:OPENAI, :RECEIPT_EXTRACTION) }
        f.response :raise_error
        f.response :json
      end

      response = conn.post("/v1/chat/completions", {
                             model: MODEL,
                             messages: [
                               { role: "system", content: prompt },
                               { role: "user", content: [*content, *candidates_content] }
                             ],
                             response_format: {
                               type: "json_schema",
                               json_schema: { name: "receipt", strict: true, schema: SCHEMA }
                             }
                           })

      extracted = begin
        JSON.parse(response.body.dig("choices", 0, "message", "content").to_s).with_indifferent_access
      rescue JSON::ParserError
        nil
      end

      return if extracted.nil?

      # the OpenAI request above can take a while; the receipt (or its file)
      # may have been deleted in the meantime, e.g. the user removed it from
      # the receipt bin. re-check freshness before persisting to avoid a
      # RecordInvalid on the "file can't be blank" validation.
      @receipt = Receipt.find_by(id: @receipt.id)
      return if @receipt.nil? || !@receipt.file.attached?

      # Only trust ids we actually offered the model.
      if extracted[:best_match_id].in?(@candidates.map(&:id))
        @best_match_hcb_code_id = extracted[:best_match_id]
        @match_confidence = extracted[:match_confidence]
      end

      @receipt.update!(
        suggested_memo: extracted[:transaction_memo],
        extracted_subtotal_amount_cents: extracted[:subtotal_amount_cents]&.to_i,
        extracted_total_amount_cents: extracted[:total_amount_cents]&.to_i,
        extracted_currency: extracted[:currency]&.upcase,
        extracted_card_last4: extracted[:card_last_four],
        extracted_date: begin
          extracted[:date]&.to_date
        rescue Date::Error
          nil
        end,
        extracted_merchant_name: extracted[:merchant_name],
        extracted_merchant_url: extracted[:merchant_url],
        extracted_merchant_zip_code: extracted[:merchant_zip_code],
        data_extracted: true
      )


      if @receipt.receiptable_type == "HcbCode"
        hcb_code = @receipt.receiptable
        hcb_code.broadcast_action_later_to(
          [hcb_code, "ai_memo"],
          action: :replace,
          target: "ai_memo",
          partial: "hcb_codes/memo/ai",
          locals: { hcb_code: }
        )

        # The ledger item's heading shows the same icon under its own target, so
        # whichever page is open picks the suggestion up.
        if (ledger_item = hcb_code.ledger_item).present?
          hcb_code.broadcast_action_later_to(
            [hcb_code, "ai_memo"],
            action: :replace,
            target: ActionView::RecordIdentifier.dom_id(ledger_item, :ai_memo),
            partial: "ledger/items/memo/ai",
            locals: { item: ledger_item }
          )
        end
      end

      unless @receipt.receiptable
        @receipt.broadcast_replace_to(
          [@receipt.user, :receipt_bin],
          target: nil,
          targets: "div[data-extracted-data-for='#{@receipt.id}']",
          partial: "receipts/extracted",
          locals: { receipt: @receipt, current_user: @receipt.user }
        )
      end

      @receipt
    end

    SCHEMA = {
      type: "object",
      additionalProperties: false,
      required: %w[
        subtotal_amount_cents total_amount_cents currency card_last_four date merchant_url
        merchant_name merchant_zip_code transaction_memo best_match_id match_confidence
      ],
      properties: {
        subtotal_amount_cents: { type: ["integer", "null"] },
        total_amount_cents: { type: ["integer", "null"], description: "the amount likely to be charged to a credit card" },
        currency: { type: ["string", "null"], description: "3-letter ISO 4217 currency code" },
        card_last_four: { type: ["string", "null"] },
        date: { type: ["string", "null"], description: "in the format of YYYY-MM-DD" },
        merchant_url: { type: ["string", "null"], description: "URL for merchant's primary website including https, if available" },
        merchant_name: { type: ["string", "null"], description: "short recognizable concise common name without identifiers or order numbers" },
        merchant_zip_code: { type: ["string", "null"] },
        transaction_memo: { type: ["string", "null"] },
        best_match_id: { type: ["integer", "null"], description: "id of the candidate transaction this receipt is for, or null if none clearly match" },
        match_confidence: { type: ["string", "null"], enum: ["high", "medium", "low", nil] }
      }
    }.freeze

    private

    def prompt
      <<~PROMPT
        You are a helpful assistant that extracts important features from receipts.

        transaction_memo: a good memo includes quantity (if it's more than one), the item(s) purchased, and the merchant. pretend someone will use the memos in the sentence, "In this transaction, I purchased (a) <memo>" where <memo> is what you generate. some good examples are "🏷️ 5,000 Event stickers from StickerMule", "💧 Office water supply from Culligan", "🔌 USB-C cable for MacBook", "💾 10 Airtable team seats for December", and "🚕 Uber to SFO Airport". avoid generic quantifiers like "multiple", "many", or "assorted", using improper capitalization, unnecessarily verbose descriptions, addresses, and transaction/merchant/order IDs. Ensure memos are less than 60 characters.

        If candidate transactions are provided, set best_match_id to the id of the one this receipt is for. Card statements often show a different merchant name than the receipt (e.g. "AMZN Mktp US" for Amazon), and the charged amount may include a tip or currency conversion. If none of them clearly match, return null.

        If you can't extract a feature, or if you can't find any features, return null for the respective keys.
      PROMPT
    end

    def file_content
      content_type = @receipt.file.content_type
      data = @receipt.file.download

      if content_type == "application/pdf"
        pdf_content(data) || text_content
      elsif content_type.start_with?("image/")
        image_content(content_type, data) || text_content
      elsif content_type == "text/csv"
        [{ type: "text", text: data.force_encoding("UTF-8").scrub.truncate(80_000) }]
      end
    end

    def pdf_content(data)
      return if data.bytesize > MAX_PDF_BYTES || pdf_page_count(data).to_i > MAX_PDF_PAGES

      [{ type: "file", file: { filename: @receipt.file.filename.to_s, file_data: data_url("application/pdf", data) } }]
    end

    def pdf_page_count(data)
      Poppler::Document.new(data).n_pages
    rescue GLib::ErrorInfo
      Float::INFINITY
    end

    def image_content(content_type, data)
      [{ type: "image_url", image_url: { url: image_data_url(content_type, data) } }]
    rescue MiniMagick::Error, ImageProcessing::Error
      # ImageMagick can't read every image we accept (e.g. some HEICs), so
      # fall back to whatever text OCR got out of it.
      nil
    end

    def text_content
      text = @receipt.textual_content || @receipt.extract_textual_content![:text]
      return if text.blank?

      [{ type: "text", text: text.truncate(80_000, omission: "...#{text.last(40_000)}") }]
    end

    def image_data_url(content_type, data)
      Tempfile.create(["receipt", File.extname(@receipt.file.filename.to_s)], binmode: true) do |source|
        source.write(data)
        source.flush

        pipeline = ImageProcessing::MiniMagick.source(source.path).resize_to_limit(MAX_IMAGE_DIMENSION, MAX_IMAGE_DIMENSION)
        pipeline = pipeline.convert("png") unless content_type.in?(SUPPORTED_IMAGE_TYPES)
        processed = pipeline.call

        data_url(content_type.in?(SUPPORTED_IMAGE_TYPES) ? content_type : "image/png", File.binread(processed.path))
      ensure
        processed&.close!
      end
    end

    def data_url(content_type, data)
      "data:#{content_type};base64,#{Base64.strict_encode64(data)}"
    end

    def candidates_content
      return [] if @candidates.empty?

      rows = @candidates.map do |hcb_code|
        merchant = hcb_code.stripe_merchant || {}
        {
          id: hcb_code.id,
          amount_cents: hcb_code.amount_cents.abs,
          merchant_amount: hcb_code.stripe_merchant_amount&.then { |m| { cents: m.cents, currency: m.currency.iso_code } },
          date: hcb_code.date&.iso8601,
          merchant_name: merchant["name"],
          merchant_zip_code: merchant["postal_code"],
          card_last_four: hcb_code.card&.last4
        }
      end

      [{ type: "text", text: "Candidate transactions:\n#{rows.to_json}" }]
    end

  end
end
