# frozen_string_literal: true

require "rexml/document"
require "set"

DEFAULT_FILE = File.expand_path(
  "../ip-cosell/decision-chart.drawio",
  __dir__
)

DECISION_CHART_CATEGORIES = {
  "saas" => ["[IP]", "#E69F00"],
  "container" => ["[IP]", "#E69F00"],
  "vm" => ["[IP]", "#E69F00"],
  "managed" => ["[IP]", "#E69F00"],
  "professional" => ["[TX]", "#56B4E9"],
  "template" => ["[NO]", "#0072B2"],
  "github" => ["[NO]", "#0072B2"],
  "service" => ["[NO]", "#0072B2"],
  "legend-ip" => ["[IP]", "#E69F00"],
  "legend-tx" => ["[TX]", "#56B4E9"],
  "legend-no" => ["[NO]", "#0072B2"]
}.freeze

def attribute(element, name)
  return "" unless element

  element.attributes.get_attribute(name)&.value.to_s
end

def number_attribute(element, name)
  value = attribute(element, name)
  value.empty? ? nil : Float(value)
end

def validate_bounds(cells_by_id, errors)
  background = cells_by_id["3"]
  return unless background

  bounds = REXML::XPath.first(background, "mxGeometry")
  return unless bounds

  left = number_attribute(bounds, "x")
  top = number_attribute(bounds, "y")
  width = number_attribute(bounds, "width")
  height = number_attribute(bounds, "height")
  return unless [left, top, width, height].all?

  right = left + width
  bottom = top + height

  cells_by_id.each_value do |cell|
    next if cell.equal?(background) || attribute(cell, "vertex") != "1"

    geometry = REXML::XPath.first(cell, "mxGeometry")
    next unless geometry

    x = number_attribute(geometry, "x")
    y = number_attribute(geometry, "y")
    cell_width = number_attribute(geometry, "width")
    cell_height = number_attribute(geometry, "height")
    next unless [x, y, cell_width, cell_height].all?

    next if x >= left && y >= top && x + cell_width <= right &&
            y + cell_height <= bottom

    errors << "#{attribute(cell, 'id')}: geometry exceeds background bounds"
  end
end

def validate_decision_chart(document, cells_by_id, errors)
  diagram = REXML::XPath.first(document, "//diagram")
  return unless diagram && attribute(diagram, "id") == "marketplace-offer-tree"

  DECISION_CHART_CATEGORIES.each do |id, (prefix, fill)|
    cell = cells_by_id[id]
    unless cell
      errors << "missing required cell: #{id}"
      next
    end

    value = attribute(cell, "value")
    style = attribute(cell, "style")
    errors << "#{id}: value must start with #{prefix}" unless value.start_with?(prefix)
    errors << "#{id}: expected fillColor=#{fill}" unless style.include?("fillColor=#{fill}")
  end

  professional = attribute(cells_by_id["professional"], "value")
  unless professional.include?("US, UK, or Canada") &&
         professional.include?("Remote only")
    errors << "professional: missing market or remote-delivery limitation"
  end

  managed_note = attribute(cells_by_id["managed-app-note"], "value")
  unless managed_note.include?("no separate software offer") &&
         managed_note.include?("management fee may be $0") &&
         managed_note.include?("Azure usage is billed separately")
    errors << "managed-app-note: missing no-software-offer pricing guidance"
  end
end

def validate_file(file_path)
  document = REXML::Document.new(File.read(file_path))
  cells = REXML::XPath.match(document, "//mxCell")
  errors = []
  seen_ids = Set.new
  cells_by_id = {}

  cells.each do |cell|
    id = attribute(cell, "id")
    errors << "mxCell without an id" if id.empty?
    errors << "duplicate mxCell id: #{id}" unless seen_ids.add?(id)
    cells_by_id[id] = cell unless id.empty?
  end

  edges = cells.select { |cell| attribute(cell, "edge") == "1" }
  edges.each do |edge|
    %w[source target].each do |endpoint|
      reference = attribute(edge, endpoint)
      unless !reference.empty? && cells_by_id.key?(reference)
        errors << "#{attribute(edge, 'id')}: invalid #{endpoint} #{reference.inspect}"
      end
    end
  end

  validate_bounds(cells_by_id, errors)
  validate_decision_chart(document, cells_by_id, errors)

  if errors.empty?
    puts "PASS #{file_path}: #{cells.length} cells, #{edges.length} edges"
    return true
  end

  warn "FAIL #{file_path}:"
  errors.each { |error| warn "  - #{error}" }
  false
rescue Errno::ENOENT
  warn "FAIL #{file_path}: file not found"
  false
rescue REXML::ParseException => error
  warn "FAIL #{file_path}: invalid XML: #{error.message.lines.first.strip}"
  false
end

files = ARGV.empty? ? [DEFAULT_FILE] : ARGV
exit(files.all? { |file_path| validate_file(File.expand_path(file_path)) } ? 0 : 1)