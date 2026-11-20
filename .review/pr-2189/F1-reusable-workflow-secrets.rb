#!/usr/bin/env ruby
# frozen_string_literal: true

# Review repro for open-component-model/ocm PR #2189, finding F1.
#
# GitHub rule (docs: "Reuse workflows" > "Using inputs and secrets in a reusable workflow"):
#   "To use an environment secret in a reusable workflow, set environment on the job in the
#    reusable workflow. [...] The caller workflow must still pass the secret. Use secrets: inherit
#    or pass the secret by name [...] If the caller workflow doesn't pass an environment secret,
#    the secret resolves to an empty string in the reusable workflow."
#
# The check: every secret a reusable workflow reads must be passed by each local caller,
# either with `secrets: inherit` or by name. Secrets passed by name must be declared under
# `on.workflow_call.secrets` in the callee.
#
# Usage: F1-reusable-workflow-secrets.rb [repo-root]
# Exit:  0 = every caller passes what the callee reads, 1 = reproduced, 2 = inconclusive.

require "yaml"

root = ARGV[0] || "."
dir = File.join(root, ".github", "workflows")
files = Dir.glob(File.join(dir, "*.{yml,yaml}")).sort
if files.empty?
  warn "inconclusive: no workflows under #{dir}"
  exit 2
end

def trigger(doc)
  # YAML 1.1 parses the bare key `on` as boolean true.
  doc["on"] || doc[true]
end

workflows = files.to_h do |f|
  [File.basename(f), YAML.safe_load(File.read(f), aliases: true)]
rescue StandardError => e
  warn "inconclusive: cannot parse #{f}: #{e.message}"
  exit 2
end

callees = {}
workflows.each do |name, doc|
  on = trigger(doc)
  next unless on.is_a?(Hash) && on.key?("workflow_call")

  declared = ((on["workflow_call"] || {})["secrets"] || {}).keys
  reads = {}
  (doc["jobs"] || {}).each do |job_id, job|
    names = job.to_s.scan(/secrets\.([A-Za-z0-9_]+)/).flatten.uniq.reject { |s| s.casecmp?("GITHUB_TOKEN") }
    env = job["environment"]
    env = env["name"] if env.is_a?(Hash)
    names.each { |n| reads[n] = { job: job_id, environment: env } }
  end
  callees[name] = { declared: declared, reads: reads }
end

failures = 0
calls = 0
workflows.each do |caller_name, doc|
  (doc["jobs"] || {}).each do |job_id, job|
    uses = job["uses"]
    next unless uses.is_a?(String) && uses.start_with?("./.github/workflows/")

    callee_name = File.basename(uses)
    callee = callees[callee_name]
    unless callee
      warn "inconclusive: #{caller_name}/#{job_id} calls #{callee_name}, which has no workflow_call trigger"
      exit 2
    end
    calls += 1
    passed = job["secrets"]
    callee[:reads].each do |secret, where|
      ok = passed == "inherit" || (passed.is_a?(Hash) && passed.key?(secret))
      mode = passed.nil? ? "passes no secrets" : "passes #{passed.inspect}"
      if ok
        puts "ok    #{caller_name}/#{job_id} -> #{callee_name}/#{where[:job]}: #{secret} is passed"
      else
        failures += 1
        puts "FAIL  #{caller_name}/#{job_id} -> #{callee_name}/#{where[:job]} " \
             "(environment: #{where[:environment] || 'none'}): reads secrets.#{secret}, caller #{mode} " \
             "=> resolves to an empty string"
      end
    end
    next unless passed.is_a?(Hash)

    (passed.keys - callee[:declared]).each do |secret|
      failures += 1
      puts "FAIL  #{caller_name}/#{job_id} passes #{secret} by name, but #{callee_name} does not declare it " \
           "under on.workflow_call.secrets"
    end
  end
end

puts "checked #{calls} local reusable-workflow call(s), #{failures} problem(s)"
exit(failures.zero? ? 0 : 1)
