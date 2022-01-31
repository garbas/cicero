{ self, pkgs, ... }:

{
  imports = [
    self.nixosModule
    self.inputs.driver.nixosModules.nix-driver-nomad
    "${self.inputs.nixpkgs}/nixos/modules/profiles/headless.nix"
    "${self.inputs.nixpkgs}/nixos/modules/profiles/minimal.nix"
  ];

  nixpkgs.overlays = [ self.overlay ];

  nix = {
    package = pkgs.nixUnstable;
    extraOptions = ''
      experimental-features = nix-command flakes ca-references
    '';
  };

  networking.firewall.enable = false;

  services = {
    cicero.enable = true;

    postgresql.enableTCPIP = true;
  };
}
