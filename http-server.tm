#!/bin/env tomo

# This file provides an HTTP server module and standalone executable

use <stdio.h>
use <stdlib.h>
use <string.h>
use <unistd.h>
use <arpa/inet.h>
use <err.h>

use commands
use pthreads
use patterns

use ./connection-queue.tm

func serve(port:Int32, handler:func(request:HTTPRequest -> HTTPResponse), num_threads=16)
    connections := ConnectionQueue()
    workers : &[PThread]
    for i in num_threads
        workers.insert(PThread.new(func()
            repeat
                connection := connections.dequeue()
                request_text := ""
                C_code`
                    char buf[1024] = {};
                    for (ssize_t n; (n = read(@connection, buf, sizeof(buf) - 1)) > 0; ) {
                        buf[n] = 0;
                        @request_text = Text$concat(@request_text, Text$from_strn(buf, n));
                        if (@request_text.length > 1000000 || strstr(buf, "\\r\\n\\r\\n"))
                            break;
                    }
                `
                request := HTTPRequest.from_text(request_text) or skip
                response := handler(request).bytes()
                C_code `
                    if (@response.stride != 1)
                        List$compact(&@response, 1);
                    write(@connection, @response.data, @response.length);
                    close(@connection);
                `
        ))


    sock := C_code:Int32`
        int s = socket(AF_INET, SOCK_STREAM, 0);
        if (s < 0) err(1, "Couldn't connect to socket!");

        int opt = 1;
        if (setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt)) < 0)
            err(1, "Couldn't set socket option");

        struct sockaddr_in addr = {AF_INET, htons(@port), INADDR_ANY};
        if (bind(s, (struct sockaddr*)&addr, sizeof(addr)) < 0)
            err(1, "Couldn't bind to socket");
        if (listen(s, 8) < 0)
            err(1, "Couldn't listen on socket");

        s
    `

    repeat
        conn := C_code:Int32`accept(@sock, NULL, NULL)`
        stop if conn < 0 
        connections.enqueue(conn)

    say("Shutting down...")
    for w in workers
        w.cancel()

struct HTTPRequest(method:Text, path:Text, version:Text, headers:[Text], body:Text)
    func from_text(text:Text -> HTTPRequest?)
        m := $Pat'{word} {..} HTTP/{..}{crlf}{..}'.match(text) or return none
        method := m.captures[1]!
        path := $Pat'{2+ /}'.replace(m.captures[2]!, '/')
        version := m.captures[3]!
        rest := $Pat'{..}{2 crlf}{0+ ..}'.match(m.captures[-1]!) or return none
        headers := $Pat'{crlf}'.split(rest.captures[1]!)
        body := rest.captures[-1]!
        return HTTPRequest(method, path, version, headers, body)

struct HTTPResponse(body:Text, status=200, content_type="text/plain", headers:{Text:Text}={})
    func bytes(r:HTTPResponse -> [Byte])
        body_bytes := r.body.utf8()
        extra_headers := (++: "$k: $v\r\n" for k,v in r.headers) or ""
        return "
            HTTP/1.1 $(r.status) OK\r
            Content-Length: $(body_bytes.length + 2)\r
            Content-Type: $(r.content_type)\r
            Connection: close\r
            $extra_headers
            \r\n
        ".utf8() ++ body_bytes

func _content_type(file:Path -> Text)
    when file.extension() is "html" return "text/html"
    is "tm" return "text/html"
    is "js" return "text/javascript"
    is "css" return "text/css"
    else return "text/plain"

enum RouteEntry(ServeFile(file:Path), Redirect(destination:Text))
    func respond(entry:RouteEntry, request:HTTPRequest -> HTTPResponse)
        when entry is ServeFile(f)
            body := if f.can_execute()
                Command(Text(f)).get_output()!
            else
                f.read()!
            return HTTPResponse(body, content_type=_content_type(f))
        is Redirect(destination)
            return HTTPResponse("Found", 302, headers={"Location":destination})

func load_routes(directory:Path -> {Text:RouteEntry})
    routes : &{Text:RouteEntry}
    for file in (directory ++ (./*)).glob()
        skip unless file.is_file()
        server_path := "/" ++ "/".join(file.relative_to(directory).components())
        if file.base_name() == "index.html"
            canonical := server_path.without_suffix("index.html")
            routes[server_path] = Redirect(canonical)
            routes[canonical] = ServeFile(file)
        else if file.extension() == "html"
            canonical := server_path.without_suffix(".html")
            routes[server_path] = Redirect(canonical)
            routes[canonical] = ServeFile(file)
        else if file.extension() == "tm"
            canonical := server_path.without_suffix(".tm")
            routes[server_path] = Redirect(canonical)
            routes[canonical] = ServeFile(file)
        else
            routes[server_path] = ServeFile(file)
    return routes[]

func main(directory:Path, port=Int32(8080))
    say("Serving on port $port")
    routes := load_routes(directory)
    say("Hosting: $routes")

    serve(port, func(request:HTTPRequest)
        if handler := routes[request.path]
            return handler.respond(request)
        else
            return HTTPResponse("Not found!", 404)
    )

