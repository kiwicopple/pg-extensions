# YAML -> JSON for test/fga_abac/vendor.sh, with Psych's restricted loader
# (the same class loader and scalar scanner YAML.safe_load uses: only plain
# data, no object instantiation).
#
#   ruby test/fga_abac/yaml2json.rb <file.yaml>   # JSON on stdout
#
# One difference from YAML.safe_load + JSON.generate: a plain (unquoted) float
# scalar keeps its source text as the JSON number. abac_tests.yaml has
# 1.79769313486231570814527423731704356798070e+309, beyond float64: Ruby would
# read it as Infinity, which JSON can't carry. As text it stays the number the
# file wrote (jsonb holds it exactly), and fga_check must reject it as a
# double parameter, as OpenFGA does (case handles_floats).
require 'yaml'
require 'json'

NUM = /\A-?(0|[1-9]\d*)(\.\d+)?([eE][+-]?\d+)?\z/

raw = {}
doc = Psych.parse(File.read(ARGV.fetch(0)))
loader = Psych::ClassLoader::Restricted.new([], [])
scanner = Psych::ScalarScanner.new(loader)

walk = lambda do |n|
  if n.is_a?(Psych::Nodes::Scalar)
    if !n.quoted && n.tag.nil? && scanner.tokenize(n.value).is_a?(Float)
      abort "yaml2json: float scalar is not a JSON number: #{n.value}" unless n.value =~ NUM
      key = "\u0001raw#{raw.size}\u0001"
      raw[key] = n.value
      n.value = key
      n.quoted = true
      n.plain = false
    end
  else
    (n.children || []).each { |c| walk.call(c) }
  end
end
walk.call(doc)

obj = Psych::Visitors::ToRuby.new(scanner, loader).accept(doc)
out = JSON.generate(obj)
raw.each do |k, v|
  out = out.sub(JSON.generate(k), v)
end
abort 'yaml2json: a raw number was not substituted' if out.include?('\u0001')
puts out
