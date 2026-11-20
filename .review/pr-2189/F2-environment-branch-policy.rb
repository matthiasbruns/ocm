#!/usr/bin/env ruby
# frozen_string_literal: true

# Review repro for open-component-model/ocm PR #2189, finding F2.
#
# GitHub rule (docs: "Deployments and environments" > "Deployment branches and tags"):
#   "The deployment branch or tag rule is matched against the GITHUB_REF of the workflow run."
#
# The check: for every workflow in the given tree that has a job with an `environment`
# (directly or through a local reusable workflow), take the branches that workflow has
# actually run on (GitHub run history) and match them against the live deployment branch
# policy of that environment. Read-only: it only issues GET requests through `gh api`.
#
# Usage: F2-environment-branch-policy.rb [repo-root] [--assume-policy ENV=pattern,pattern ...]
# Env:   REPO (default open-component-model/ocm), RUNS (default 30)
# Exit:  0 = every observed branch is allowed, 1 = reproduced, 2 = inconclusive.

require "yaml"
require "json"
require "open3"

repo = ENV.fetch("REPO", "open-component-model/ocm")
runs = ENV.fetch("RUNS", "30")
root = "."
assumed = {}
args = ARGV.dup
until args.empty?
  a = args.shift
  if a == "--assume-policy"
    env, patterns = args.shift.to_s.split("=", 2)
    assumed[env] = patterns.to_s.split(",")
  else
    root = a
  end
end

def gh(*cmd)
  out, err, status = Open3.capture3("gh", *cmd)
  unless status.success?
    warn "inconclusive: gh #{cmd.join(' ')} failed: #{err.strip}"
    exit 2
  end
  out
end

dir = File.join(root, ".github", "workflows")
workflows = Dir.glob(File.join(dir, "*.{yml,yaml}")).sort.to_h do |f|
  [File.basename(f), YAML.safe_load(File.read(f), aliases: true)]
end
if workflows.empty?
  warn "inconclusive: no workflows under #{dir}"
  exit 2
end

def environments_of(doc)
  (doc["jobs"] || {}).filter_map do |job_id, job|
    env = job["environment"]
    env = env["name"] if env.is_a?(Hash)
    [job_id, env] if env
  end
end

# workflow file => [[job path, environment]]
uses_env = Hash.new { |h, k| h[k] = [] }
workflows.each do |name, doc|
  on = doc["on"] || doc[true]
  callable_only = on.is_a?(Hash) && on.keys == ["workflow_call"]
  environments_of(doc).each { |job_id, env| uses_env[name] << [job_id, env] } unless callable_only
  (doc["jobs"] || {}).each do |job_id, job|
    uses = job["uses"]
    next unless uses.is_a?(String) && uses.start_with?("./.github/workflows/")

    callee = workflows[File.basename(uses)]
    next unless callee

    environments_of(callee).each { |cjob, env| uses_env[name] << ["#{job_id} -> #{File.basename(uses)}/#{cjob}", env] }
  end
end

policies = {}
uses_env.values.flatten(1).map(&:last).uniq.each do |env|
  if assumed.key?(env)
    policies[env] = assumed[env]
    next
  end
  meta = JSON.parse(gh("api", "repos/#{repo}/environments/#{env}"))
  dbp = meta["deployment_branch_policy"]
  policies[env] =
    if dbp.nil?
      nil # no restriction
    elsif dbp["custom_branch_policies"]
      JSON.parse(gh("api", "repos/#{repo}/environments/#{env}/deployment-branch-policies"))["branch_policies"]
          .select { |p| p["type"] == "branch" }.map { |p| p["name"] }
    else
      warn "inconclusive: environment #{env} uses the protected-branches policy, not covered by this script"
      exit 2
    end
end
policies.each do |env, pats|
  source = assumed.key?(env) ? "assumed" : "live"
  puts "policy #{env} (#{source}): #{pats.nil? ? 'any branch' : pats.join(', ')}"
end

failures = 0
checked = 0
uses_env.sort.each do |wf, jobs|
  history = JSON.parse(gh("run", "list", "--repo", repo, "--workflow", wf, "--limit", runs, "--json", "headBranch,event"))
  branches = history.map { |r| r["headBranch"] }.compact.uniq.sort
  if branches.empty?
    puts "skip  #{wf}: no run history"
    next
  end
  jobs.uniq.each do |job, env|
    branches.each do |branch|
      checked += 1
      pats = policies[env]
      allowed = pats.nil? || pats.any? { |p| File.fnmatch(p, branch, File::FNM_PATHNAME) }
      if allowed
        puts "ok    #{wf} [#{job}] environment=#{env} branch=#{branch}"
      else
        failures += 1
        puts "FAIL  #{wf} [#{job}] environment=#{env} branch=#{branch}: not matched by #{pats.inspect}"
      end
    end
  end
end

if checked.zero?
  warn "inconclusive: nothing checked"
  exit 2
end
puts "checked #{checked} (job, branch) pair(s), #{failures} not allowed by the environment's branch policy"
exit(failures.zero? ? 0 : 1)
