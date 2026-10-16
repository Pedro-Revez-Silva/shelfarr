#!/usr/bin/env ruby
# frozen_string_literal: true

require "base64"
require "fileutils"
require "json"
require "net/http"
require "socket"
require "uri"

module ShelfarrDrive
  module_function

  def main(argv)
    command = argv.shift
    flags = parse_flags(argv)
    case command
    when "start" then start(flags)
    when "open" then open_url(flags)
    when "fill" then fill(flags)
    when "click" then click(flags)
    when "wait" then wait_for(flags)
    when "shot" then shot(flags)
    when "location" then location(flags)
    when "stop" then stop(flags)
    else
      warn "usage: drive.rb start|open|fill|click|wait|shot|location|stop"
      2
    end
  end

  def parse_flags(argv)
    flags = {}
    index = 0
    while index < argv.length
      token = argv[index]
      abort "missing value for #{token}" unless token.start_with?("--") && argv[index + 1]
      flags[token.delete_prefix("--")] = argv[index + 1]
      index += 2
    end
    flags
  end

  def start(flags)
    state_path = required(flags, "state")
    abort "browser already recorded at #{state_path}" if File.exist?(state_path) && process_alive?(load_state(state_path)["chrome_pid"])

    width = (flags["width"] || "1280").to_i
    height = (flags["height"] || "900").to_i
    port = free_port
    root = File.dirname(state_path)
    profile = File.join(root, "chrome-profile")
    log_path = File.join(root, "chrome.log")
    FileUtils.mkdir_p(root)
    FileUtils.rm_rf(profile)
    FileUtils.mkdir_p(profile)
    pid = Process.spawn(
      chrome_bin,
      "--headless=new",
      "--no-sandbox",
      "--disable-dev-shm-usage",
      "--disable-gpu",
      "--remote-debugging-address=127.0.0.1",
      "--remote-debugging-port=#{port}",
      "--user-data-dir=#{profile}",
      "--window-size=#{width},#{height}",
      "--no-first-run",
      "--no-default-browser-check",
      "--disable-extensions",
      "about:blank",
      pgroup: true,
      in: File::NULL,
      out: log_path,
      err: log_path
    )
    Process.detach(pid)
    state = {
      "chrome_pid" => pid,
      "port" => port,
      "profile" => profile,
      "width" => width,
      "height" => height,
      "log" => log_path
    }
    save_state(state_path, state)
    wait_until(15) { devtools_up?(port) }
    page = page_target(port)
    abort "chrome opened no page" unless page
    puts "chrome #{pid} port #{port}"
    0
  end

  def open_url(flags)
    target = required(flags, "url")
    with_page(flags) do |page|
      page.call("Page.enable")
      before = page.eval("location.href")
      page.call("Page.navigate", url: target)
      last = nil
      stable = 0
      finished = wait_until((flags["timeout"] || "20").to_f) do
        href = page.eval("location.href")
        ready = page.eval("document.readyState") == "complete"
        arrived = same_page?(href, target) || (href != before && ready)
        if arrived && ready && href == last
          stable += 1
        else
          stable = 0
          last = href if arrived && ready
        end
        stable >= 2
      end
      abort "page did not finish loading #{target} (last #{last})" unless finished
      puts last
    end
    0
  end

  def fill(flags)
    placeholder = required(flags, "placeholder")
    text = required(flags, "text")
    find_js, value_js = field_scripts(placeholder)
    with_page(flags) do |page|
      point = page.eval(find_js)
      abort "field #{placeholder} is #{point["status"]}" unless point["status"] == "ok"
      page.click_at(point["x"], point["y"])
      page.select_all
      page.type_text(text)
      actual = page.eval(value_js)
      abort "field #{placeholder} holds #{actual.inspect}" unless actual == text
    end
    0
  end

  def click(flags)
    role = required(flags, "role")
    name = required(flags, "name")
    with_page(flags) do |page|
      status = page.eval(<<~JS)
        (() => {
          const role = #{role.to_json};
          const name = #{name.to_json};
          const nodes = [...document.querySelectorAll("a, button, input[type='submit']")];
          const label = (el) => (el.getAttribute("value") || el.innerText || el.textContent || "").replace(/\\s+/g, " ").trim();
          const visible = (el) => {
            const rect = el.getBoundingClientRect();
            const style = getComputedStyle(el);
            return style.visibility !== "hidden" && style.display !== "none" && rect.width > 0 && rect.height > 0;
          };
          const matches = nodes.filter((el) => {
            if (label(el) !== name) return false;
            if (role === "link") return el.tagName === "A";
            if (role === "submit") return el.getAttribute("type") === "submit" || el.tagName === "BUTTON";
            return true;
          }).filter(visible);
          if (matches.length === 0) return "missing";
          matches[0].click();
          return "ok";
        })()
      JS
      abort "control #{role} #{name} is #{status}" unless status == "ok"
    end
    0
  end

  def wait_for(flags)
    needle = required(flags, "text")
    timeout = (flags["timeout"] || "20").to_f
    with_page(flags) do |page|
      found = wait_until(timeout) do
        page.eval("document.body ? document.body.innerText.includes(#{needle.to_json}) : false")
      end
      unless found
        url = page.eval("location.href") rescue "unknown"
        warn "timed out waiting for #{needle} at #{url}"
        return 1
      end
    end
    0
  end

  def shot(flags)
    path = required(flags, "path")
    with_page(flags) do |page|
      page.call("Page.enable")
      png = page.call("Page.captureScreenshot", format: "png")
      FileUtils.mkdir_p(File.dirname(path))
      File.open(path, File::WRONLY | File::CREAT | File::EXCL) do |file|
        file.write(Base64.decode64(png.fetch("data")))
      end
    end
    puts path
    0
  end

  def location(flags)
    with_page(flags) do |page|
      puts page.eval("location.href")
    end
    0
  end

  def stop(flags)
    state_path = required(flags, "state")
    return 0 unless File.exist?(state_path)

    pid = load_state(state_path)["chrome_pid"].to_i
    if process_alive?(pid)
      Process.kill("TERM", -pid)
      wait_until(10) { !process_alive?(pid) }
      Process.kill("KILL", -pid) if process_alive?(pid)
    end
    0
  rescue Errno::ESRCH, Errno::EPERM
    0
  end

  def with_page(flags)
    state = load_state(required(flags, "state"))
    page = Page.new(page_target(state.fetch("port")).fetch("webSocketDebuggerUrl"))
    page.call(
      "Emulation.setDeviceMetricsOverride",
      width: state.fetch("width"),
      height: state.fetch("height"),
      deviceScaleFactor: 1,
      mobile: false
    )
    page.call("Page.bringToFront")
    yield page
  ensure
    page&.close
  end

  def same_page?(actual, expected)
    current = URI(actual)
    wanted = URI(expected)
    current.host == wanted.host && current.port == wanted.port && current.path.chomp("/") == wanted.path.chomp("/")
  end

  def field_scripts(placeholder)
    case placeholder
    when "Enter your username"
      [ FIND_USERNAME, VALUE_USERNAME ]
    when "Enter your password"
      [ FIND_PASSWORD, VALUE_PASSWORD ]
    else
      abort "unknown placeholder"
    end
  end

  FIND_USERNAME = <<~JS
    (() => {
      const el = document.querySelector('input[placeholder="Enter your username"]');
      if (!el) return { status: "missing" };
      const rect = el.getBoundingClientRect();
      if (rect.width < 1 || rect.height < 1) return { status: "hidden" };
      el.focus();
      return { status: "ok", x: rect.x + rect.width / 2, y: rect.y + rect.height / 2 };
    })()
  JS
  VALUE_USERNAME = <<~JS
    document.querySelector('input[placeholder="Enter your username"]').value
  JS
  FIND_PASSWORD = <<~JS
    (() => {
      const el = document.querySelector('input[placeholder="Enter your password"]');
      if (!el) return { status: "missing" };
      const rect = el.getBoundingClientRect();
      if (rect.width < 1 || rect.height < 1) return { status: "hidden" };
      el.focus();
      return { status: "ok", x: rect.x + rect.width / 2, y: rect.y + rect.height / 2 };
    })()
  JS
  VALUE_PASSWORD = <<~JS
    document.querySelector('input[placeholder="Enter your password"]').value
  JS

  def chrome_bin
    return ENV["CHROME_BIN"] if ENV["CHROME_BIN"] && File.executable?(ENV["CHROME_BIN"])

    path = [
      "/usr/local/bin/google-chrome",
      "/usr/bin/google-chrome-stable",
      "/usr/bin/google-chrome",
      "/usr/bin/chromium",
      "/usr/bin/chromium-browser"
    ].find { |candidate| File.executable?(candidate) }
    abort "Chrome is not installed" unless path
    path
  end

  def free_port
    server = TCPServer.new("127.0.0.1", 0)
    server.addr[1]
  ensure
    server&.close
  end

  def devtools_up?(port)
    http_get("http://127.0.0.1:#{port}/json/version")
    true
  rescue StandardError
    false
  end

  def page_target(port)
    targets = JSON.parse(http_get("http://127.0.0.1:#{port}/json/list"))
    targets.find { |target| target["type"] == "page" }
  end

  def http_get(url)
    uri = URI(url)
    Net::HTTP.start(uri.host, uri.port, open_timeout: 2, read_timeout: 5) do |http|
      response = http.get(uri.request_uri)
      abort "HTTP #{response.code} for #{url}" unless response.is_a?(Net::HTTPSuccess)
      response.body
    end
  end

  def load_state(path)
    JSON.parse(File.read(path))
  end

  def save_state(path, state)
    File.write(path, JSON.generate(state))
  end

  def process_alive?(pid)
    pid = pid.to_i
    return false if pid <= 0

    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  def wait_until(timeout)
    deadline = Time.now + timeout
    loop do
      return true if yield
      return false if Time.now >= deadline

      sleep 0.2
    end
  end

  def required(flags, key)
    value = flags[key]
    abort "missing --#{key}" if value.nil? || value.empty?
    value
  end

  class Page
    def initialize(ws_url)
      @cdp = SocketClient.new(ws_url)
    end

    def call(method, params = {})
      @cdp.call(method, params)
    end

    def eval(expression)
      result = call("Runtime.evaluate", expression: expression, returnByValue: true, awaitPromise: true)
      details = result["exceptionDetails"]
      abort "javascript error: #{details.dig("exception", "description") || details}" if details

      result.dig("result", "value")
    end

    def click_at(x, y)
      [ "mousePressed", "mouseReleased" ].each do |kind|
        call("Input.dispatchMouseEvent", type: kind, x: x, y: y, button: "left", clickCount: 1)
      end
    end

    def select_all
      call("Input.dispatchKeyEvent", type: "keyDown", key: "a", code: "KeyA", windowsVirtualKeyCode: 65, nativeVirtualKeyCode: 65, modifiers: 2)
      call("Input.dispatchKeyEvent", type: "keyUp", key: "a", code: "KeyA", windowsVirtualKeyCode: 65, nativeVirtualKeyCode: 65, modifiers: 2)
    end

    def type_text(text)
      text.each_char do |char|
        call("Input.dispatchKeyEvent", type: "keyDown", text: char, key: char, unmodifiedText: char)
        call("Input.dispatchKeyEvent", type: "keyUp", key: char)
      end
    end

    def close
      @cdp.close
    end
  end

  class SocketClient
    def initialize(ws_url)
      uri = URI(ws_url)
      @socket = TCPSocket.new(uri.host, uri.port)
      key = Base64.strict_encode64(Random.bytes(16))
      @socket.write(
        "GET #{uri.request_uri} HTTP/1.1\r\n" \
        "Host: #{uri.host}:#{uri.port}\r\n" \
        "Upgrade: websocket\r\n" \
        "Connection: Upgrade\r\n" \
        "Sec-WebSocket-Key: #{key}\r\n" \
        "Sec-WebSocket-Version: 13\r\n\r\n"
      )
      response = +""
      while (line = @socket.gets)
        response << line
        break if line == "\r\n"
      end
      abort "websocket upgrade failed" unless response.include?(" 101 ")
      @next_id = 0
    end

    def call(method, params = {})
      @next_id += 1
      id = @next_id
      send_text(JSON.generate(id: id, method: method, params: params))
      loop do
        message = JSON.parse(read_text)
        next unless message["id"] == id
        abort "cdp #{method} failed: #{message["error"]}" if message["error"]

        return message["result"] || {}
      end
    end

    def close
      @socket.close
    rescue IOError
      nil
    end

    def send_text(payload)
      send_frame(0x1, payload)
    end

    def send_frame(opcode, payload)
      data = payload.b
      mask = Random.bytes(4)
      header = [ 0x80 | opcode ].pack("C")
      length = data.bytesize
      if length < 126
        header << [ 0x80 | length ].pack("C")
      elsif length < 65_536
        header << [ 0x80 | 126 ].pack("C") << [ length ].pack("n")
      else
        header << [ 0x80 | 127 ].pack("C") << [ length ].pack("Q>")
      end
      masked = data.bytes.each_with_index.map { |byte, index| byte ^ mask.bytes[index % 4] }.pack("C*")
      @socket.write(header + mask + masked)
    end

    def read_text
      chunks = []
      opcode = nil
      loop do
        first, second = read_bytes(2).unpack("CC")
        fin = (first & 0x80) != 0
        op = first & 0x0f
        masked = (second & 0x80) != 0
        length = second & 0x7f
        length = read_bytes(2).unpack1("n") if length == 126
        length = read_bytes(8).unpack1("Q>") if length == 127
        mask = read_bytes(4).bytes if masked
        data = read_bytes(length)
        if mask
          data = data.bytes.each_with_index.map { |byte, index| byte ^ mask[index % 4] }.pack("C*")
        end
        if op == 0x9
          send_frame(0xA, data)
          next
        end
        next if op == 0xA
        abort "websocket closed" if op == 0x8
        if op.zero?
          chunks << data
        else
          opcode = op
          chunks = [ data ]
        end
        next unless fin
        abort "non-text websocket frame #{opcode}" unless opcode == 1

        return chunks.join
      end
    end

    def read_bytes(count)
      buffer = +""
      while buffer.bytesize < count
        chunk = @socket.read(count - buffer.bytesize)
        abort "websocket closed" if chunk.nil?

        buffer << chunk
      end
      buffer
    end
  end
end

exit ShelfarrDrive.main(ARGV) if $PROGRAM_NAME == __FILE__
