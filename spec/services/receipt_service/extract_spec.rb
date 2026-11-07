# frozen_string_literal: true

require "rails_helper"

RSpec.describe ReceiptService::Extract do
  def build_receipt(fixture: "receipt.png", content_type: "image/png", **attributes)
    user = create(:user)
    Receipt.new(upload_method: :api, user:, textual_content: "some receipt text", **attributes).tap do |receipt|
      receipt.file.attach(
        io: StringIO.new(File.binread(Rails.root.join("spec/fixtures/files", fixture))),
        filename: fixture,
        content_type:
      )
      receipt.save!
    end
  end

  def sent_content
    request = WebMock::RequestRegistry.instance.requested_signatures.hash.keys.last
    JSON.parse(request.body).dig("messages", 1, "content")
  end

  let(:extracted_data) do
    described_class::SCHEMA[:required].index_with(nil).merge(
      transaction_memo: "☕ Coffee from Cafe",
      total_amount_cents: 500,
      currency: "usd"
    )
  end

  let(:ai_response_body) do
    {
      choices: [
        {
          message: {
            content: extracted_data.to_json
          }
        }
      ]
    }.to_json
  end

  before do
    stub_request(:post, "https://api.openai.com/v1/chat/completions")
      .to_return(status: 200, body: ai_response_body, headers: { "Content-Type" => "application/json" })
  end

  it "persists the extracted data onto the receipt" do
    receipt = build_receipt

    described_class.new(receipt:).run!

    receipt.reload
    expect(receipt.data_extracted?).to be(true)
    expect(receipt.suggested_memo).to eq("☕ Coffee from Cafe")
  end

  describe "file content" do
    it "sends images as a data URL" do
      described_class.new(receipt: build_receipt).run!

      expect(sent_content.sole).to include("type" => "image_url")
      expect(sent_content.sole.dig("image_url", "url")).to start_with("data:image/png;base64,")
    end

    it "falls back to the OCR text when the image can't be processed" do
      allow_any_instance_of(ImageProcessing::Builder).to receive(:call).and_raise(MiniMagick::Error)

      described_class.new(receipt: build_receipt).run!

      expect(sent_content).to eq([{ "type" => "text", "text" => "some receipt text" }])
    end

    it "sends small PDFs as a file" do
      described_class.new(receipt: build_receipt(fixture: "receipt.pdf", content_type: "application/pdf")).run!

      expect(sent_content.sole).to include("type" => "file")
      expect(sent_content.sole.dig("file", "file_data")).to start_with("data:application/pdf;base64,")
    end

    it "sends the text of PDFs with too many pages" do
      stub_const("#{described_class}::MAX_PDF_PAGES", 0)

      described_class.new(receipt: build_receipt(fixture: "receipt.pdf", content_type: "application/pdf")).run!

      expect(sent_content).to eq([{ "type" => "text", "text" => "some receipt text" }])
    end

    it "sends the text of PDFs that are too big" do
      stub_const("#{described_class}::MAX_PDF_BYTES", 1)

      described_class.new(receipt: build_receipt(fixture: "receipt.pdf", content_type: "application/pdf")).run!

      expect(sent_content).to eq([{ "type" => "text", "text" => "some receipt text" }])
    end

    it "skips the request when there is nothing to send" do
      allow_any_instance_of(ImageProcessing::Builder).to receive(:call).and_raise(MiniMagick::Error)
      receipt = build_receipt(textual_content: "")

      described_class.new(receipt:).run!

      expect(WebMock).not_to have_requested(:post, "https://api.openai.com/v1/chat/completions")
      expect(receipt.reload.data_extracted?).to be(true)
    end
  end

  describe "candidates" do
    let(:candidate) do
      instance_double(
        HcbCode,
        id: 123,
        amount_cents: -500,
        stripe_merchant: { "name" => "CAFE", "postal_code" => "05401" },
        stripe_merchant_amount: nil,
        date: Date.new(2026, 10, 1),
        card: nil
      )
    end

    let(:best_match_id) { 123 }

    let(:extracted_data) do
      described_class::SCHEMA[:required].index_with(nil).merge(best_match_id:, match_confidence: "high")
    end

    it "sends the candidates and keeps the model's pick" do
      extract = described_class.new(receipt: build_receipt, candidates: [candidate])
      extract.run!

      expect(sent_content.last["text"]).to include('"id":123', '"merchant_name":"CAFE"')
      expect(extract.best_match_hcb_code_id).to eq(123)
      expect(extract.match_confidence).to eq("high")
    end

    context "when the model picks an id it wasn't offered" do
      let(:best_match_id) { 456 }

      it "ignores the pick" do
        extract = described_class.new(receipt: build_receipt, candidates: [candidate])
        extract.run!

        expect(extract.best_match_hcb_code_id).to be_nil
        expect(extract.match_confidence).to be_nil
      end
    end
  end

  # The OpenAI request above is slow enough that a user can delete the
  # receipt (or its file) from under the job while it's in flight. Before the
  # fix, the final `@receipt.update!` would re-validate `attached: true`
  # against the now-gone attachment and raise ActiveRecord::RecordInvalid
  # ("File can't be blank") instead of just no-oping.
  it "does not raise when the receipt is deleted while the extraction request is in flight" do
    receipt = build_receipt

    stub_request(:post, "https://api.openai.com/v1/chat/completions")
      .to_return do |_request|
        # simulate a separate request (e.g. the user deleting the receipt from
        # the UI) racing the job, rather than mutating the job's own in-memory
        # object directly
        Receipt.find(receipt.id).destroy!
        { status: 200, body: ai_response_body, headers: { "Content-Type" => "application/json" } }
      end

    expect { described_class.new(receipt:).run! }.not_to raise_error
    expect(Receipt.exists?(receipt.id)).to be(false)
  end
end
