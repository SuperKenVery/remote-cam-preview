{
  description = "Reproducible development tools for Remote Cam Preview";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "aarch64-darwin"
        "x86_64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      pkgsFor =
        system:
        import nixpkgs {
          inherit system;
          config = {
            allowUnfree = true;
            android_sdk.accept_license = true;
          };
        };
    in
    {
      devShells = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          android = pkgs.androidenv.composeAndroidPackages {
            platformVersions = [ "36" ];
            buildToolsVersions = [ "36.0.0" ];
            includeEmulator = false;
            includeSystemImages = false;
            includeCmake = false;
            includeNDK = false;
          };
          androidSdk = android.androidsdk;
          jdk = pkgs.jdk21;
        in
        {
          default = pkgs.mkShell {
            name = "remote-cam-preview";
            packages = [
              androidSdk
              android.platform-tools
              pkgs.detekt
              pkgs.git
              pkgs.gradle
              pkgs.jq
              jdk
              pkgs.kotlin
              pkgs.ktlint
              pkgs.nixfmt
              pkgs.python3
            ]
            ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [
              pkgs.swiftformat
              pkgs.xcodegen
            ];

            ANDROID_HOME = "${androidSdk}/libexec/android-sdk";
            ANDROID_SDK_ROOT = "${androidSdk}/libexec/android-sdk";
            JAVA_HOME = jdk.home;
            LANG = "en_US.UTF-8";
            LC_ALL = "en_US.UTF-8";

            shellHook = ''
              echo "Remote Cam Preview development shell"
              echo "  JDK:     ${jdk.version}"
              echo "  Gradle:  ${pkgs.gradle.version}"
              echo "  Kotlin:  ${pkgs.kotlin.version}"
              echo "  Android: platform 36 / build-tools 36.0.0"
              if [ "$(uname -s)" = Darwin ]; then
                if command -v xcodebuild >/dev/null 2>&1; then
                  echo "  Xcode:   $(xcodebuild -version | head -n 1) (external)"
                else
                  echo "  Xcode:   missing; Xcode 26+ is required for iOS builds"
                fi
              fi
            '';
          };
        }
      );

      checks = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          protocol = pkgs.runCommand "remote-cam-protocol-tests" { nativeBuildInputs = [ pkgs.python3 ]; } ''
            cp -R ${./protocol} protocol
            chmod -R u+w protocol
            python3 -m unittest discover -s protocol/tests -t . -v
            touch $out
          '';

          nix-format = pkgs.runCommand "remote-cam-nix-format" { nativeBuildInputs = [ pkgs.nixfmt ]; } ''
            cp ${./flake.nix} flake.nix
            nixfmt --check flake.nix
            touch $out
          '';
        }
      );

      formatter = forAllSystems (system: (pkgsFor system).nixfmt);
    };
}
