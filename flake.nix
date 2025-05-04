{
  description = "Local Kubernetes data platform";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = {nixpkgs, ...}: let
    systems = [
      "x86_64-linux"
      "aarch64-linux"
      "x86_64-darwin"
      "aarch64-darwin"
    ];

    forEachSystem = nixpkgs.lib.genAttrs systems;

    pkgsFor = system:
      import nixpkgs {
        inherit system;
        config = {};
      };
  in {
    formatter = forEachSystem (system: (pkgsFor system).alejandra);

    devShells = forEachSystem (system: let
      pkgs = pkgsFor system;
    in {
      default = pkgs.mkShell {
        packages = with pkgs; [
          kind
          kubectl
          kubernetes-helm
          cilium-cli
          fluxcd
          kustomize

          jq
          yq-go
          kubeconform
        ];

        shellHook = ''
          echo "Local Kubernetes data platform"
          echo "kind:    $(kind version 2>/dev/null || true)"
          echo "kubectl: $(kubectl version --client 2>/dev/null || true)"
          echo "helm:    $(helm version --short 2>/dev/null || true)"
          echo "flux:    $(flux --version 2>/dev/null || true)"
          echo "cilium:  $(cilium version --client 2>/dev/null || true)"
        '';
      };
    });
  };
}
