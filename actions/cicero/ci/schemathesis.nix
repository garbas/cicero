{ name, std, lib, actionLib, ... }@args:

{
  inputs.start = ''
    "cicero/ci": start: {
      clone_url: string
      sha: string
      statuses_url?: string
    }
  '';

  job = { start }:
    let cfg = start.value."cicero/ci".start; in
    std.chain args [
      actionLib.jobDefaults

      (std.escapeNames [ ] [ ])

      {
        ${name}.group.schemathesis = {
          network = {
            mode = "bridge";
            port.cicero = {};
          };

          task = {
            cicero = {
              lifecycle = {
                hook = "prestart";
                sidecar = true;
              };

              config.nixos = "github:input-output-hk/cicero/${cfg.sha}#nixosConfigurations.cicero";

              template = [{
                destination = "/etc/cicero/start.args";
                data = ''
                  --web-listen :{{ env "NOMAD_PORT_cicero" }}

                  ${""/*
                    Do not try to connect to Nomad
                    as we have none running.
                  */}
                  web
                '';
              }];
            };

            schemathesis = std.chain args [
              (std.networking.addNameservers [ "1.1.1.1" ])

              (lib.optionalAttrs (cfg ? statuses_url)
                (std.github.reportStatus cfg.statuses_url))

              (std.git.clone cfg)

              {
                config.packages = std.data-merge.append [
                  "github:input-output-hk/cicero/${cfg.sha}#devShell.x86_64-linux"
                ];
              }

              (std.script "bash" ''
                exec schemathesis run http://127.0.0.1:$NOMAD_PORT_cicero/documentation/cicero.yaml --validate-schema=false
              '')
            ];
          };
        };
      }
    ];
}
