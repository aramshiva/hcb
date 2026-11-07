# frozen_string_literal: true

module ReceiptService
  class Suggest
    include Turbo::Streams::ActionHelper
    include Turbo::Streams::StreamName

    def initialize(receipt:)
      @receipt = receipt
    end

    MAX_CANDIDATES = 25

    TIE_BREAK_MARGIN = 10

    def run!(include_details: false)
      return nil if user.nil?

      @text = @receipt.textual_content || @receipt.extract_textual_content![:text]

      extract = ::ReceiptService::Extract.new(receipt: @receipt, candidates: @receipt.receiptable.nil? ? candidates : [])
      @extracted = extract.run!

      best_match_hcb_code_id = extract.best_match_hcb_code_id || (quick_match&.id if @receipt.receiptable.nil?)
      pairings = break_tie(transaction_distances(include_details:), best_match_hcb_code_id)

      if pairings.present?
        pairs = pairings.map do |pairing|
          {
            receipt_id: @receipt.id,
            hcb_code_id: pairing[:hcb_code].id,
            distance: pairing[:distance],
            aasm_state: "unreviewed"
          }
        end

        pairings = SuggestedPairing.upsert_all(pairs, unique_by: [:receipt_id, :hcb_code_id]) if pairs.any?

        if @receipt.receiptable.nil?
          content = turbo_stream_action_tag(:refresh_suggested_pairings)
          Turbo::StreamsChannel.broadcast_action_to([@receipt.user, :receipt_bin], action: :refresh_suggested_pairings)

          if @receipt.email_receipt_bin? && (pair = auto_accept_pairing(extract))
            pair.mark_accepted!

            return pair
          end
        end

        pairings
      end
    end

    def distance(hcb_code)
      return if @extracted.nil?

      merchant_amount = hcb_code.pt&.raw_pending_stripe_transaction&.stripe_transaction&.[]("merchant_amount")

      distances = {
        amount_cents: {
          value: @extracted.extracted_total_amount_cents && ((merchant_amount || hcb_code.amount_cents).abs - @extracted.extracted_total_amount_cents.abs).abs == 0 ? 0 : 1,
          weight: 200,
        },
        card_last_four: {
          value: @extracted.extracted_card_last4 == hcb_code.card&.last4 ? 0 : 1,
          weight: 200,
        },
        date: {
          value: begin
            if @extracted.extracted_date.present?
              distance = ((hcb_code.pt&.raw_pending_stripe_transaction&.created_at || hcb_code.date).to_date - @extracted.extracted_date.to_date).abs

              if distance <= 1
                0
              elsif distance <= 5
                0.2 + 0.8 * (distance / 5)
              else
                1
              end
            else
              1
            end
          end,
          weight: 100,
        },
        merchant_zip_code: {
          value: begin
            stripe_zip = hcb_code.stripe_merchant["postal_code"]
            if stripe_zip == "00000"
              nil
              # https://mapofzipcodes.com/blog/00000-zip-code
              # many postal codes are reported as 000000, and we don't
              # want a lack of information to hurt pairing suggestions
            else
              stripe_zip = stripe_zip.to_i
              receipt_zip = @extracted.extracted_merchant_zip_code.to_i
              distance = (stripe_zip - receipt_zip).abs
              if distance.zero?
                0
              elsif distance < 75
                0.5
              else
                1
              end
            end
          end,
          weight: 50,
        },
        merchant_name: {
          value: @extracted.extracted_merchant_name&.downcase&.in?(hcb_code.stripe_merchant["name"]&.downcase) ? 0 : 1,
          weight: 50,
        }
      }

      features = distances.values.reject { |data| data[:value].nil? }

      value = features.map { |data| data[:value] * data[:weight] }.sum.to_f
      weight = features.map { |data| data[:weight] }.sum.to_f

      value / weight * 100
    end

    def sorted_transactions
      transaction_distances.sort_by { |match| match[:distance] }
    end

    def best_match
      sorted_transactions.first
    end

    private

    def auto_accept_pairing(extract)
      closest = @receipt.suggested_pairings
                        .unreviewed
                        .where("distance <= ?", 20)
                        .order(:receipt_id, distance: :asc)
                        .select("DISTINCT ON (receipt_id) suggested_pairings.*")
                        .select { |pairing| pairing.hcb_code.missing_receipt? }
                        .first

      closest || sole_candidate_pairing(extract)
    end

    def sole_candidate_pairing(extract)
      return unless potential_hcb_codes.one? && @extracted&.extracted_total_amount_cents
      return unless extract.match_confidence.in?(%w[high medium])

      hcb_code = potential_hcb_codes.sole
      return unless extract.best_match_hcb_code_id == hcb_code.id && hcb_code.missing_receipt?

      merchant_amount = hcb_code.stripe_merchant_amount
      total = @extracted.extracted_total_amount_cents.abs
      amount_matches = total == hcb_code.amount_cents.abs ||
                       (merchant_amount.present? && @extracted.extracted_currency == merchant_amount.currency.iso_code && total == merchant_amount.cents)
      return unless amount_matches

      @receipt.suggested_pairings.unreviewed.find_by(hcb_code:)
    end

    def quick_match
      return if @text.blank?

      amounts = @text.scan(/(?<![\d.,])\d+(?:[,.]\d{3})*[.,]\d{2}(?![\d.,])/).map { |amount| amount.gsub(/\D/, "").to_i }.to_set
      return if amounts.empty?

      normalized_text = @text.downcase

      matches = potential_hcb_codes.select do |hcb_code|
        hcb_code_amounts = [hcb_code.amount_cents.abs, hcb_code.stripe_merchant_amount&.cents].compact
        next false unless hcb_code_amounts.any? { |amount| amount.in?(amounts) }

        last4 = hcb_code.card&.last4
        merchant_word = hcb_code.stripe_merchant&.dig("name")&.downcase&.scan(/[a-z]{4,}/)&.first

        (last4.present? && normalized_text.match?(/\b#{last4}\b/)) ||
          (merchant_word.present? && normalized_text.include?(merchant_word))
      end

      matches.sole if matches.one?
    end

    def break_tie(pairings, best_match_hcb_code_id)
      best_distance = pairings.filter_map { |pairing| pairing[:distance] }.min
      pick = pairings.find { |pairing| pairing[:hcb_code].id == best_match_hcb_code_id }
      return pairings if best_distance.nil? || pick.nil? || pick[:distance].nil?
      return pairings if pick[:distance] > best_distance + TIE_BREAK_MARGIN

      pairings.map do |pairing|
        next pairing if pairing.equal?(pick) || pairing[:distance].nil? || pairing[:distance] > best_distance + TIE_BREAK_MARGIN

        pairing.merge(distance: pairing[:distance] + TIE_BREAK_MARGIN)
      end
    end

    def candidates
      potential_hcb_codes.sort_by.with_index do |hcb_code, index|
        amount = hcb_code.amount_cents.abs
        formatted = format("%d.%02d", amount / 100, amount % 100)
        [@text.to_s.include?(formatted) ? 0 : 1, index]
      end.first(MAX_CANDIDATES)
    end

    def transaction_distances(include_details: false)
      potential_hcb_codes.map do |hcb_code|
        {
          hcb_code:,
          distance: distance(hcb_code)
        }
      end
    end

    def user
      @receipt.user
    end

    def potential_hcb_codes
      @potential_hcb_codes ||= user.transactions_missing_receipt.to_a
    end

  end
end
