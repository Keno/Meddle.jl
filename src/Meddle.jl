# Meddle is a Rack/Connect style middleware module
#
# Use the `middleware` function to build a `MidwareStack` of `Midware`.
# Pass the `MidwareStack`, plus `req::MeddleRequest, res::Response` to `handle` to
# run process the `req` through your `MidwareStack`.  
#
# Build `Midware` with functions that accept `req::MeddleRequest, res::Response`.
# `Midware` should put any data it wants to pass in the `req.state` Dict.
# 
# - Return `req, res` from your `Midware` to pass control to the next piece of 
#   `Midware` in the stack.
# - Use `respond(req, res)` to short-circut the stack and return to the client.
#
# Usage:
#
#     using Http
#     using Meddle
#
#     stack = middleware(DefaultHeaders,
#                        CookieDecoder, 
#                        FileServer(pwd()), 
#                        NotFound)    
#
#     http = HttpHandler((req, res) -> Meddle.handle(stack, req, res))
#    
#     server = Server(http)
#     run(server, 8000)
#
module Meddle

# Version const, used in `Server` header.
MEDDLE_VERSION = "0.0"

using HttpServer
export Midware,
       MeddleRequest,
       MeddleResponse,
       DefaultHeaders,
       URLDecoder,
       Cookies,
       BodyDecoder,
       FileServer, 
       NotFound, 
       MidwareStack, 
       handle, 
       middleware, 
       respond

# `Midware` only uses the `handler` right now.
# Expects & Provides may be leveraged soon to do dependency resolution
# like `expects = ["cookies"]`, `provides = ["sessions"]`.
#
immutable Midware
    handler::Function
    expects::Array
    provides::Array
end
Midware(handler::Function) = Midware(handler,[],[])

# `MidwareStack` is just an `Array` of `Midware`
typealias MidwareStack Array{Midware,1}

const empty_stack = Array(Midware,0)

type MeddleRequest{R}
    req::R
    state::Dict
    stack::MidwareStack
    stack_pos::Int
end
MeddleRequest{R}(req::R) = MeddleRequest{R}(req,Dict{Symbol,Any}(),Meddle.empty_stack,0)

immutable MeddleResponse{R}
    res::R
    state::Dict
end
MeddleResponse{R}(res::R) = MeddleResponse(res,Dict{Symbol,Any}())

# `DefaultHeaders` writes the `Server` header on the `Response`
#
# This would be good as one of the first items in your stack
# because it does not depend on any other midware, and ensures
# that any `Response` sent will include the defaults.
#
DefaultHeaders = Midware() do req::MeddleRequest, res::MeddleResponse
    res.res.headers["Server"] = string(res.res.headers["Server"], " Meddle/$MEDDLE_VERSION")
    pass(req, res)
end

# URLDecoder
#
# Decodes the URI encoding of req.resource.
# Turns the req.state[:url_query] "foo=hello%20world&bar=fun" 
# into req.state[:url_params] # => ["foo" => "hello world", "bar" => "fun"]
# 
# Should be pretty far forward in the stack, makes URLs and URL strings usable.
#
URLDecoder = Midware() do req::MeddleRequest, res::MeddleResponse
    if contains(get(req.state, :url_query, ""), '=')
        req.state[:url_params] = parsequerystring(req.state[:url_query])
    end
    req.state[:resource] = decodeURI(req.req.resource)
    pass(req, res)
end


# `CookieDecoder` builds `req.state[:cookies]` from `req.headers`.
#
# `req.state[:cookies]` will be a dictionary of Symbols to Strings.
# This should come fairly early in your stack,
# before anything that needs to use cookies.
#
Cookies = Midware() do req::MeddleRequest, res::MeddleResponse
    cookies = Dict()
    if haskey(req.req.headers, "Cookie")
        for pair in split(req.req.headers["Cookie"],"; ")
            kv = split(pair,"=",2)
            if length(kv) == 1
                cookies[kv[1]] = ""
            else
                cookies[kv[1]] = kv[2]
            end
        end
    end
    req.state[:cookies] = cookies
    req,res = pass(req, res)
    if haskey(res.state,:cookies)
        res.res.headers["Set-Cookie"] = join(["$k=$v" for (k,v) in res.state[:cookies]],",")
    end
    req,res
end

# `BodyDecoder` builds `req.state[:data]` from `req.data`.
#
# `req.state[:data]` will be a dictionary of Symbols to Strings.
# This should come fairly early in your stack,
# before anything that needs to use POST data.
#
BodyDecoder = Midware() do req::MeddleRequest, res::MeddleResponse
    if contains(req.req.data,'=') 
        req.state[:data] = parsequerystring(req.req.data)
    end
    pass(req, res)
end

# `FileServer` returns a `Midware` to serve files in `root`
#
# Checks for files that match `req.resource` relative to `root` directory.  
# If no such file exists, then it passes to the next in the stack.
# If a file is found, it short-circuts and responds.
#

mime_map = [
    ".js" => "application/javascript",
    ".css" => "text/css",
    ".png" => "image/png",
    ".jpeg" => "image/jpeg",
    ".jpg" => "image/jpeg",
    ".htm" => "text/html",
    ".html" => "test/html"
]

path_in_dir(p::String, d::String) = length(p) > length(d) && p[1:length(d)] == d

function FileServer(root::String)
    Midware() do req::MeddleRequest, res::MeddleResponse
        m = match(r"^/+(.*)$", req.state[:resource])
        if m != nothing
            path = normpath(root, m.captures[1])
            # protect against dir-escaping
            if !path_in_dir(path, root)
                return req, MeddleResponse(Response(400)) # Bad Request
            end
            if isfile(path)
                res.res.headers["Content-Type"] = get(mime_map,splitext(path)[2],"text/plain")*"; charset=utf-8"
                res.res.data = readall(path)
                return req, res
            end
        end
        pass(req, res)
    end
end

# `NotFound` always responds with a `404` error. 
#
# This is useful as the last thing in your stack
# to handle all the "no idea what to do" requests.
#
NotFound = Midware() do req::MeddleRequest, res::MeddleResponse
    req, MeddleResponse(Response(404))
end

function middleware(midware...)
    Midware[typeof(m) == Function ? m() : m::Midware for m in midware]
end

function pass(req::MeddleRequest,res::MeddleResponse) 
    if !done(req.stack,req.stack_pos)
        (mid, req.stack_pos) = next(req.stack,req.stack_pos)
        req, res = mid.handler(req,res)
    end
    req, res
end

# `handle` method runs the `req, res` through each `Midware` in `stack`.
#
# Stops and returns the response when complete ( `res.finished == true` ).
# Usually called in `HttpHandler.handle`
#
function handle(stack::MidwareStack, req::MeddleRequest, res::MeddleResponse)
    old_stack = req.stack
    old_stack_pos = req.stack_pos
    req.stack = stack
    req.stack_pos = start(stack)
    req, res = pass(req,res)
    req.stack_pos = old_stack_pos
    req.stack = old_stack
    req, res
end

# Convenience Functions

export set_status
set_status(res::MeddleResponse,status) = res.res.status = status

end # module Meddle
