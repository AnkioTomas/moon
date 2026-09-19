-- Network helpers must never log cookie headers or response bodies.
return {debug=function() end, info=function() end, warn=function() end, error=function() end}
