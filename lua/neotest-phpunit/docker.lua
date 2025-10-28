local Job = require("plenary.job")

local M = {}

local docker_cmd = "docker"

M.cache = {
  root_path = nil,
  container_id = nil,
  working_dir = nil,
  shell_path = nil,
  phpunit_path = nil,
}

M.get_root_path = function()
  if M.cache.root_path then
    return M.cache.root_path
  end

  local root_path_job = Job:new({
    command = "git",
    args = { "rev-parse", "--show-toplevel" },
  }):sync()

  local root_path

  if root_path_job then
    root_path = root_path_job[1]
  else
    root_path = vim.loop.cwd()
  end

  M.cache.root_path = root_path

  return root_path
end

M.root_path = M.get_root_path()

M.get_container_id = function(name)
  if M.cache.container_id then
    return M.cache.container_id
  end

  local container_id = Job:new({
    command = docker_cmd,
    args = { "ps", "-n", "1", "--filter", "name=" .. name, "--format", "{{.ID}}" },
  })
    :sync()[1]

  M.cache.container_id = container_id

  return container_id
end

M.get_working_dir = function(container_id)
  if M.cache.working_dir then
    return M.cache.working_dir
  end

  local working_dir = Job:new({
    command = docker_cmd,
    args = { "inspect", "--format", "{{.Config.WorkingDir}}", container_id },
  })
    :sync()[1]

  M.cache.working_dir = working_dir

  return working_dir
end

M.get_shell_path = function(container_id)
  if M.cache.shell_path then
    return M.cache.shell_path
  end

  local shell_path = Job:new({
    command = docker_cmd,
    args = {
      "exec",
      "-i",
      container_id,
      "/bin/sh",
      "-c",
      "if [ -f /bin/sh ]; then echo /bin/sh; else echo /bin/bash; fi | tr -d '\r'",
    },
  })
    :sync()[1]

  M.cache.shell_path = shell_path

  return shell_path
end

M.get_phpunit_path = function(container_id, shell_path)
  if M.cache.phpunit_path then
    return M.cache.phpunit_path
  end

  local phpunit_path = Job:new({
    command = docker_cmd,
    args = {
      "exec",
      "-i",
      container_id,
      shell_path,
      "-c",
      "if [ -f vendor/bin/phpunit ]; then echo vendor/bin/phpunit; else echo bin/phpunit; fi | tr -d '\r'",
    },
  })
    :sync()[1]

  M.cache.phpunit_path = phpunit_path

  return phpunit_path
end

M.translate_path_to_container = function(host_path, docker_workdir_path)
  if vim.startswith(host_path, M.root_path) then
    local relative_path = host_path:sub(#M.root_path + 2)
    return docker_workdir_path .. "/" .. relative_path
  end

  return host_path
end

M.build_script_args = function(args, config)
  local phpunit = args.phpunit
  local env = args.env
  local script_args = args.script_args

  local result = {}

  for k, v in pairs(env) do
    local s = k .. "=" .. v
    table.insert(result, s)
  end

  table.insert(result, phpunit)
  table.insert(result, M.translate_path_to_container(table.concat(script_args, " "), args.docker_workdir))

  if config.coverage.enabled then
    table.insert(result, config.coverage.arg .. " /tmp/coverage.xml")
  end

  return table.concat(result, " ")
end

M.get_docker_cmd = function(args, config)
  local container_id = M.get_container_id(config.container_name)
  local shell_path = M.get_shell_path(container_id)
  local phpunit_path = M.get_phpunit_path(container_id, shell_path)
  local docker_workdir_path = M.get_working_dir(container_id)

  local script = M.build_script_args({
    phpunit = phpunit_path,
    env = args.env,
    script_args = args.script_args,
    docker_workdir = docker_workdir_path,
  }, config)
  local docker_exec_cmd = { docker_cmd, "exec", "-i", container_id, shell_path, "-c", script }

  return docker_exec_cmd
end

M.copy_to_host = function(output_path, config)
  local container_id = M.get_container_id(config.container_name)

  Job:new({
    command = docker_cmd,
    args = { "cp", "-a", container_id .. ":" .. output_path, output_path },
  }):sync()

  Job:new({
    command = "sed",
    args = { "-i", "_", "s#" .. M.get_working_dir(container_id) .. "#" .. M.root_path .. "#g", output_path },
  }):sync()

  if config.coverage.enabled then
    Job
      :new({
        command = docker_cmd,
        args = { "cp", "-a", container_id .. ":" .. "/tmp/cobertura.xml", M.root_path .. "/" .. config.coverage.path },
      })
      :sync()
  end
end

return M
