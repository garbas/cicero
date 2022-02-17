self:

let
  inherit (self.inputs.nixpkgs) lib;
  inherit (self.inputs) data-merge;
in

rec {
  actions = {
    apply = part: base:
      base // part // {
        inputs =
          base.inputs or { } //
          part.inputs or { };

        output = inputs:
          lib.recursiveUpdate
            (base.output or (_: { }) inputs)
            (part.output or (_: { }) inputs);
      };

    behavior = {
      onUpdate = action: behavior.once action.id action;

      # Same as `stopOnSuccess` and `stopOnFailure` combined
      # but more efficient (just one input so only one DB query).
      # TODO this is actually not significantly more efficient
      once = key: _: next: actions.apply
        {
          inputs."behavior: run only once for \"${key}\"" = {
            not = true;
            match = ''
              "_behavior": once: "${key}": _
            '';
          };

          output = _:
            let fact._behavior.once.${key} = null; in
            { success = fact; } //
            lib.optionalAttrs (next ? job) {
              failure = fact;
            };
        }
        next;

      stopOnSuccess = key: _: actions.apply {
        inputs."behavior: stop on success for \"${key}\"" = {
          not = true;
          match = ''
            "_behavior": stopOnSuccess: "${key}": _
          '';
        };

        output = _: {
          success._behavior.stopOnSuccess.${key} = null;
        };
      };

      stopOnFailure = key: _: actions.apply {
        inputs."behavior: stop on failure for \"${key}\"" = {
          not = true;
          match = ''
            "_behavior": stopOnFailure: "${key}": _
          '';
        };

        output = _: {
          failure._behavior.stopOnFailure.${key} = null;
        };
      };

      onInputChange = input: key: _: next: actions.apply
        {
          inputs."behavior: input \"${input}\" changed for \"${key}\"" = {
            not = true;
            match = ''
              "_behavior": onInputChange: "${key}": "${input}": _inputs."${input}".id
            '';
          };

          output = inputs:
            let fact._behavior.onInputChange.${key}.${input} = inputs.${input}.id; in
            { success = fact; } //
            lib.optionalAttrs (next ? job) {
              failure = fact;
            };
        }
        next;
    };
  };

  jobs = {
    escapeNames = from: to: job:
      let
        escape = builtins.replaceStrings
          (from ++ [ "/" ])
          (to ++ [ "-" ]);
      in
      lib.mapAttrs'
        (k: v: lib.nameValuePair (escape k) (v // {
          group = builtins.mapAttrs
            (k: v: v // {
              task = lib.mapAttrs' (k: lib.nameValuePair (escape k)) v.task or { };
            }) v.group or { };
        }))
        job;

    singleTask = name: task: { ${name}.group.${name}.task.${name} = task; };
  };

  tasks.script = language: script:
    let
      runner = "cicero-evaluator-nix-run-${language}";
      scriptName = builtins.hashString "md5" script;
    in
    {
      config = {
        packages =
          [ "github:input-output-hk/cicero/${self.rev or ""}#${runner}" ];
        command = [
          # It is ok to hard-code the system here
          # because we only care about the derivation name.
          "/bin/${self.outputs.packages.x86_64-linux.${runner}.name}"
          "/local/scripts/${language}/${scriptName}"
        ];
      };

      template = [{
        destination = "local/scripts/${language}/${scriptName}";
        left_delimiter = "";
        right_delimiter = "";
        data = script;
      }];
    };

  /* Chains are a concise way to write jobs.
    Put simply chains are a fold-right of wrappers.

    Each "step/link/part" (no name defined) of a chain
    is a function that takes the action that this job
    is being defined for as its first argument
    and the next "step/link/part" as its second argument.
    These argument are supplied automatically when called
    by the `chain` function.
    It returns the job as an attribute set.

    Most "steps/links/parts" are created from a builder function
    that takes some specific arguments which are usually given
    directly in the action definition.

    This simple contract sometimes allows to use other functions
    that are not primarily meant to be used in a chain, or use
    functions that are meant for chains by themselves.
  */
  chains = {
    /* The main entrypoint to chains.

      For simplicity, plain attribute sets
      are also allowed. They will simply be merged
      with the next (if any) "step/link/part"
      using `data-merge.merge`.
    */
    chain = action: steps:
      lib.foldr
        (a: b:
          if builtins.typeOf a == "set"
          then data-merge.merge b a
          else (a action) b
        )
        { }
        steps;

    jobs = {
      escapeNames = from: to: actions: jobs.escapeNames from to;

      singleTask = { name, ... }: jobs.singleTask name;
    };

    tasks = {
      /* Like `tasks.script` but the second argument is
        a function that takes the command of the
        next script and returns the new script.

        Example:

        ```nix
        wrapScript "bash" (inner: ''
        echo 'Running …'
        time ${lib.escapeShellArgs inner}
        echo '… finished.'
        '')
        ```
      */
      wrapScript = language: outerFn: action: inner:
        let outer = script language (outerFn inner.config.command or [ ]); in
        data-merge.merge
          (lib.recursiveUpdate inner {
            config.command = outer.config.command;

            # XXX we have to pre-create these keys because they may not be present
            # see https://github.com/divnix/data-merge/issues/1
            config.packages = inner.config.packages or [ ];
            template = inner.template or [ ];
          })
          {
            config.packages = data-merge.append outer.config.packages;
            template = data-merge.append outer.template;
          };

      networking = {
        nameservers = nameservers: action: next:
          data-merge.merge
            (next // {
              # XXX we have to pre-create `template` because it may not be present
              # see https://github.com/divnix/data-merge/issues/1
              template = next.template or [ ];
            })
            {
              template = data-merge.append [{
                destination = "/etc/resolv.conf";
                left_delimiter = "";
                right_delimiter = "";
                data = lib.concatStringsSep "\n" (map (ns: "nameserver " + ns) nameservers);
              }];
            };

        addNameservers = nameservers:
          wrapScript "bash" (next: ''
            mkdir -p /etc
            for nameserver in ${lib.escapeShellArgs nameservers}; do
              echo "nameserver $nameserver" >> /etc/resolv.conf
            done
            exec ${lib.escapeShellArgs next}
          '');
      };

      nix = {
        install = action: next:
          data-merge.merge
            (lib.recursiveUpdate next {
              # XXX we have to pre-create `config.packages` because it may not be present
              # see https://github.com/divnix/data-merge/issues/1
              config.packages = next.config.packages or [ ];
            })
            {
              config.packages = data-merge.append
                [ "github:input-output-hk/nomad-driver-nix/${self.inputs.driver.rev}#wrap-nix" ];
              env.NIX_CONFIG = ''
                experimental-features = nix-command flakes
                ${next.env.NIX_CONFIG or ""}
              '';
            };

        develop = action: next:
          nix.install action (wrapScript "bash"
            (next: ''
              # https://github.com/NixOS/nix/issues/6083
              exec nix develop -L -c env -C "$PWD" ${lib.escapeShellArgs next}
            '')
            action
            next);

        build = action: next:
          nix.install action (wrapScript "bash"
            (next: ''
              if [[ -f flake.nix ]]; then
                # XXX remove flags once all follows bugs have been fixed
                nix build -L --no-write-lock-file --impure
              else
                nix-build
              fi
              exec ${lib.escapeShellArgs next}
            '')
            action
            next);
      };

      makes = target: action: next:
        data-merge.merge
          (wrapScript "bash"
            (next: ''
              m ${lib.escapeShellArg target}
              exec ${lib.escapeShellArgs next}
            '')
            action
            next
          )
          {
            config.packages = data-merge.append [ "github:fluidattacks/makes" ];
          };

      git.clone = { clone_url, sha, ... }:
        action: next:
          data-merge.merge
            (wrapScript "bash"
              (next: ''
                export SSL_CERT_FILE=/current-profile/etc/ssl/certs/ca-bundle.crt
                export HOME="$PWD/.home"

                mkdir -p "$HOME"

                git config --global credential.helper 'netrc -vkf /secrets/netrc'
                git config --global advice.detachedHead false
                git clone --quiet ${lib.escapeShellArg clone_url} src
                cd src
                git checkout ${lib.escapeShellArg sha}

                exec ${lib.escapeShellArgs next}
              '')
              action
              next)
            {
              config.packages = data-merge.append [
                "github:NixOS/nixpkgs/${self.inputs.nixpkgs.rev}#gitMinimal"
                "github:NixOS/nixpkgs/${self.inputs.nixpkgs.rev}#cacert"
              ];
            };

      github.reportStatus = statuses_url: action: next:
        data-merge.merge
          (wrapScript "bash"
            (inner: ''
              export SSL_CERT_FILE=/current-profile/etc/ssl/certs/ca-bundle.crt

              function cleanup {
                rm -f "$secret_headers"
              }
              trap cleanup EXIT

              secret_headers="$(mktemp)"

              cat >> "$secret_headers" <<EOF
              Authorization: token $(< "$NOMAD_SECRETS_DIR"/cicero/github/token)
              EOF

              function report {
                echo 'Reporting GitHub commit status: '"$1"

                set -x

                jq -nc '{
                  state: $state,
                  context: $action_name,
                  description: $description,
                  target_url: "\(env.CICERO_WEB_URL)/action/\($action_id)",
                }' \
                  --arg state "$1" \
                  --arg description "Run $NOMAD_JOB_ID" \
                  --arg action_id ${lib.escapeShellArg action.id} \
                  --arg action_name ${lib.escapeShellArg action.name} \
                | curl ${lib.escapeShellArg statuses_url} \
                  --output /dev/null --fail-with-body \
                  --no-progress-meter \
                  -H 'Accept: application/vnd.github.v3+json' \
                  -H @"$secret_headers" \
                  --data-binary @-
              }

              function err {
                report error
              }
              trap err ERR

              report pending

              if ${lib.escapeShellArgs inner}; then
                report success
              else
                status=$?
                report failure
                exit $status
              fi
            '')
            action
            next)
          {
            config.packages = data-merge.append [
              "github:NixOS/nixpkgs/${self.inputs.nixpkgs.rev}#curl"
              "github:NixOS/nixpkgs/${self.inputs.nixpkgs.rev}#jq"
              "github:NixOS/nixpkgs/${self.inputs.nixpkgs.rev}#cacert"
            ];

            template = data-merge.append [{
              destination = "secrets/cicero/github/token";
              data = ''{{with secret "kv/data/cicero/github"}}{{.Data.data.token}}{{end}}'';
            }];
          };
    };
  };

  inherit (actions) behavior;
  inherit (tasks) script;
  inherit (chains) chain;
  inherit (chains.jobs) escapeNames singleTask;
  inherit (chains.tasks) wrapScript networking nix makes git github;
  inherit data-merge;
}
