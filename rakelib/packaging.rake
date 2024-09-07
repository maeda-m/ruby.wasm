wasi_vfs = RubyWasm::WasiVfsProduct.new(File.join(Dir.pwd, "build"))
wasi_sdk = TOOLCHAINS["wasi-sdk"]
def exe_rbwasm = File.expand_path(File.join(__dir__, "..", "exe", "rbwasm"))

tools = {
  "WASI_VFS_CLI" => exe_rbwasm,
  "WASMOPT" => wasi_sdk.wasm_opt
}

def npm_pkg_build_command(pkg)
  # Skip if the package does not require building ruby
  return nil unless pkg[:ruby_version] && pkg[:target]
  [
    exe_rbwasm,
    "build",
    "--ruby-version",
    pkg[:ruby_version],
    "--target",
    pkg[:target],
    "--build-profile",
    "full"
  ]
end

def npm_pkg_rubies_cache_key(pkg)
  vendor_gem_cache(pkg)

  build_command = npm_pkg_build_command(pkg)
  return nil unless build_command
  require "open3"
  cmd = build_command + ["--print-ruby-cache-key"]
  chdir = pkg[:gemfile] ? File.dirname(pkg[:gemfile]) : Dir.pwd
  env = { "RUBY_WASM_ROOT" => LIB_ROOT }
  stdout, status = Open3.capture2(env, *cmd, chdir: chdir)
  unless status.success?
    raise "Command failed with status (#{status.exitstatus}): #{cmd.join " "}"
  end
  require "json"
  JSON.parse(stdout)["hexdigest"]
end

def vendor_gem_cache(pkg)
  return unless pkg[:gemfile]
  pkg_dir = File.dirname(pkg[:gemfile])
  pkg_dir = File.expand_path(pkg_dir)
  vendor_cache_dir = File.join(pkg_dir, "vendor", "cache")
  mkdir_p vendor_cache_dir
  require_relative "../packages/gems/js/lib/js/version"
  sh "gem", "-C", "packages/gems/js", "build", "-o",
    File.join(vendor_cache_dir, "js-#{JS::VERSION}.gem")
  JS::VERSION
end

namespace :npm do
  NPM_PACKAGES.each do |pkg|
    base_dir = Dir.pwd
    pkg_dir = "#{Dir.pwd}/packages/npm-packages/#{pkg[:name]}"

    namespace pkg[:name] do
      desc "Build ruby for npm package #{pkg[:name]}"
      task "ruby" do
        build_command = npm_pkg_build_command(pkg)
        # Skip if the package does not require building ruby
        next unless build_command

        js_gem_version = vendor_gem_cache(pkg)

        env = {
          # Share ./build and ./rubies in the same workspace
          "RUBY_WASM_ROOT" => base_dir
        }
        cwd = nil
        if gemfile_path = pkg[:gemfile]
          cwd = File.dirname(gemfile_path)
        else
          # Explicitly disable rubygems integration since Bundler finds
          # Gemfile in the repo root directory.
          build_command.push "--disable-gems"
        end
        dist_dir = File.join(pkg_dir, "dist")
        mkdir_p dist_dir
        if pkg[:target].start_with?("wasm32-unknown-wasi")
          Dir.chdir(cwd || base_dir) do
            # Uninstall js gem to re-install just-built js gem
            sh "gem", "uninstall", "js", "-v", js_gem_version, "--force"
            # Install gems including js gem
            sh "bundle", "install"

            sh env,
               "bundle", "exec",
               *build_command,
               "--no-stdlib", "--remake",
               "-o",
               File.join(dist_dir, "ruby.wasm")
            sh env,
               "bundle", "exec",
               *build_command,
               "-o",
               File.join(dist_dir, "ruby.debug+stdlib.wasm")
            if pkg[:enable_component_model]
              component_path = File.join(pkg_dir, "tmp", "ruby.component.wasm")
              FileUtils.mkdir_p(File.dirname(component_path))

              # Remove js gem from the ./bundle directory to force Bundler to re-install it
              rm_rf FileList[File.join(pkg_dir, "bundle", "**", "js-#{js_gem_version}")]

              sh env.merge("RUBY_WASM_EXPERIMENTAL_DYNAMIC_LINKING" => "1"),
                 *build_command, "-o", component_path
              sh "npx", "jco", "transpile",
                "--no-wasi-shim", "--instantiation", "--valid-lifting-optimization",
                component_path, "-o", File.join(dist_dir, "component")
              # ./component/package.json is required to be an ES module
              File.write(File.join(dist_dir, "component", "package.json"), '{ "type": "module" }')
            end
          end
          sh wasi_sdk.wasm_opt,
             "--strip-debug",
             File.join(dist_dir, "ruby.wasm"),
             "-o",
             File.join(dist_dir, "ruby.wasm")
          sh wasi_sdk.wasm_opt,
             "--strip-debug",
             File.join(dist_dir, "ruby.debug+stdlib.wasm"),
             "-o",
             File.join(dist_dir, "ruby+stdlib.wasm")
        elsif pkg[:target] == "wasm32-unknown-emscripten"
          Dir.chdir(cwd || base_dir) do
            sh env, *build_command, "-o", "/dev/null"
          end
        end
      end

      desc "Build npm package #{pkg[:name]}"
      task "build" => ["ruby"] do
        sh tools, "npm run build", chdir: pkg_dir
      end

      desc "Check npm package #{pkg[:name]}"
      task "check" do
        sh "npm test", chdir: pkg_dir
      end
    end

    desc "Make tarball for npm package #{pkg[:name]}"
    task pkg[:name] do
      wasi_sdk.install_binaryen
      Rake::Task["npm:#{pkg[:name]}:build"].invoke
      sh "npm pack", chdir: pkg_dir
    end
  end

  desc "Configure for pre-release"
  task :configure_prerelease, [:prerel] do |t, args|
    require "json"
    prerel = args[:prerel]
    new_pkgs = {}
    NPM_PACKAGES.each do |pkg|
      pkg_dir = "#{Dir.pwd}/packages/npm-packages/#{pkg[:name]}"
      pkg_json = "#{pkg_dir}/package.json"
      package = JSON.parse(File.read(pkg_json))

      version = package["version"] + "-#{prerel}"
      new_pkgs[package["name"]] = version
      sh *["npm", "pkg", "set", "version=#{version}"], chdir: pkg_dir
    end

    NPM_PACKAGES.each do |pkg|
      pkg_dir = "#{Dir.pwd}/packages/npm-packages/#{pkg[:name]}"
      pkg_json = "#{pkg_dir}/package.json"
      package = JSON.parse(File.read(pkg_json))
      (package["dependencies"] || []).each do |dep, _|
        next unless new_pkgs[dep]
        sh *["npm", "pkg", "set", "dependencies.#{dep}=#{new_pkgs[dep]}"],
           chdir: pkg_dir
      end
    end
  end

  desc "Build all npm packages"
  multitask all: NPM_PACKAGES.map { |pkg| pkg[:name] }
end

namespace :standalone do
  STANDALONE_PACKAGES.each do |pkg|
    pkg_dir = "#{Dir.pwd}/packages/standalone/#{pkg[:name]}"

    desc "Build standalone package #{pkg[:name]}"
    task "#{pkg[:name]}" => ["build:#{pkg[:build]}"] do
      wasi_sdk.install_binaryen
      base_dir = Dir.pwd
      sh tools,
         "./build-package.sh #{base_dir}/rubies/ruby-#{pkg[:build]}",
         chdir: pkg_dir
    end
  end
end

namespace :gem do
  task :update_component_adapters do
    ["command", "reactor"].each do |exec_model|
      sh "curl", "-L", "-o", "lib/ruby_wasm/packager/component_adapter/wasi_snapshot_preview1.#{exec_model}.wasm",
          "https://github.com/bytecodealliance/wasmtime/releases/download/v19.0.1/wasi_snapshot_preview1.#{exec_model}.wasm"
    end
  end
end
