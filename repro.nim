import repro_project_dsl
import repro_dsl_stdlib/foreign_env

package nimlangserverEnvironment:
  devEnv:
    useFlakeDevShell(flakeRef = "./dev-setup/nix")
