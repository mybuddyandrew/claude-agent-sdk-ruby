require "spec_helper"
require "skein/embedder"

RSpec.describe Skein::Embedder do
  describe ".vector_to_blob" do
    it "returns a binary string of correct size" do
      vec = [1.0, 2.0, 3.0]
      blob = described_class.vector_to_blob(vec)
      expect(blob).to be_a(String)
      expect(blob.bytesize).to eq(12)
    end
  end

  describe ".blob_to_vector" do
    it "roundtrips a simple vector" do
      vec = [1.0, 2.0, 3.0]
      blob = described_class.vector_to_blob(vec)
      result = described_class.blob_to_vector(blob)
      expect(result.size).to eq(vec.size)
      vec.each_with_index do |v, i|
        expect(result[i]).to be_within(0.0001).of(v)
      end
    end
  end

  describe "roundtrip with 384 dimensions" do
    it "preserves all values" do
      vec = Array.new(384) { rand(-1.0..1.0) }
      blob = described_class.vector_to_blob(vec)
      result = described_class.blob_to_vector(blob)
      expect(result.size).to eq(384)
      expect(blob.bytesize).to eq(384 * 4)
      vec.each_with_index do |v, i|
        expect(result[i]).to be_within(0.0001).of(v)
      end
    end
  end

  describe "empty vector" do
    it "roundtrips an empty array" do
      vec = []
      blob = described_class.vector_to_blob(vec)
      result = described_class.blob_to_vector(blob)
      expect(result).to eq([])
      expect(blob.bytesize).to eq(0)
    end
  end

  describe "constants" do
    it "defines DIMENSIONS and DEFAULT_MODEL" do
      expect(Skein::Embedder::DIMENSIONS).to eq(384)
      expect(Skein::Embedder::DEFAULT_MODEL).to eq("sentence-transformers/all-MiniLM-L6-v2")
    end
  end
end
