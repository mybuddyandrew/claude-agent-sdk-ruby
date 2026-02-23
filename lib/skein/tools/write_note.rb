require "fileutils"

module Skein
  module Tools
    module WriteNote
      def self.definition
        {
          name: "write_note",
          description: "Write a note to the notes directory. Use this to save information, meeting notes, " \
                       "ideas, or anything the user wants to remember.",
          input_schema: {
            type: "object",
            properties: {
              title: { type: "string", description: "Short title for the note (used as filename)" },
              content: { type: "string", description: "The note content in markdown" }
            },
            required: ["title", "content"]
          }
        }
      end

      def self.requires_approval?
        true
      end

      def self.execute(input, config: nil, **)
        title = input["title"]
        content = input["content"]
        return "Error: 'title' is required" unless title.is_a?(String) && !title.empty?
        return "Error: 'content' is required" unless content.is_a?(String) && !content.empty?

        notes_dir = config&.notes_dir || ENV.fetch("SKEIN_NOTES_DIR", "docs/notes")
        FileUtils.mkdir_p(notes_dir)

        # Sanitize title for filename
        slug = title.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/^-|-$/, "")
        slug = "untitled" if slug.empty?
        timestamp = Time.now.utc.strftime("%Y%m%d-%H%M%S")
        filename = "#{timestamp}-#{slug}.md"
        filepath = File.join(notes_dir, filename)

        File.write(filepath, "# #{title}\n\n#{content}\n")
        "Note saved: #{filename}"
      end
    end
  end
end
