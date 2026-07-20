// tflint config for super-linter (TERRAFORM_TFLINT).
//
// Mirrors the repository's own tflint behaviour: ci.yml runs
// `tflint --chdir=terraform` with only the bundled terraform ruleset. This keeps
// the terraform "recommended" preset but drops super-linter's bundled azurerm /
// aws / google provider rulesets, whose `azurerm_resources_missing_prevent_destroy`
// rule is inappropriate here - this is a deliberately teardownable demo
// (one-command up/down), so `prevent_destroy = true` would block the documented
// teardown.
config {
  call_module_type = "none"
  force            = false
}

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}
