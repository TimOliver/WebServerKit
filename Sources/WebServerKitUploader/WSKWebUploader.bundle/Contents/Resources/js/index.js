/*
 Copyright (c) 2012-2019, Pierre-Olivier Latour
 All rights reserved.
 
 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:
 * Redistributions of source code must retain the above copyright
 notice, this list of conditions and the following disclaimer.
 * Redistributions in binary form must reproduce the above copyright
 notice, this list of conditions and the following disclaimer in the
 documentation and/or other materials provided with the distribution.
 * The name of Pierre-Olivier Latour may not be used to endorse
 or promote products derived from this software without specific
 prior written permission.
 
 THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
 ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 DISCLAIMED. IN NO EVENT SHALL PIERRE-OLIVIER LATOUR BE LIABLE FOR ANY
 DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

var ENTER_KEYCODE = 13;

// The root, not null: _reload() is called with _path from handlers that can fire before
// the first listing comes back (the Refresh button, the EventSource "open" callback), and
// a null there used to reach path.split("/") and throw. jQuery's Callbacks.fire has no
// try/catch and .always() sits on the same list, so the throw also skipped the reload guard's
// release — it stuck "busy" and every later reload queued forever, freezing the UI and holding an
// /events slot open for nothing. That guard is no longer a counter; see _reloadInFlight below.
var _path = "/";
// The path most recently ASKED for. _path is only assigned when a listing comes back, so between
// _reload(hashPath) and its response it still reads "/" — and the SSE onopen re-sync fired in that
// window re-requested "/", landing the user at the root. That made every deep link, and simply
// pressing Reload inside a subfolder, bounce to the top (33 of 40 attempts), which is the opposite
// of what this file's own "Restore path from URL hash on page load" comment intends.
var _requestedPath = "/";
var _pathRendered = false;  // The breadcrumb starts empty, so the first listing must always draw it.
var _pendingReloads = [];
// Owned SOLELY by _reload(), and cleared in its .always(), which jQuery always runs. It used to be a
// counter that two independent parties incremented and decremented — _reload() around its own
// request, and the rename box between onedit and onsubmit/onreset — and a counter like that is only
// ever as correct as its least reliable decrement. It has now wedged twice for two different
// reasons: once when a throw skipped _enableReloads() (see the note on _path above), and once when a
// listing arrived while the rename box was open, because $("#listing").empty() destroys the box so
// jeditable's onsubmit and onreset never fire and the onedit increment is never matched. Both left
// it stuck above zero with every later reload queued forever, and the page silently stopped tracking
// the share.
//
// Decrementing by the number of destroyed editors — the obvious repair — makes it worse: jeditable's
// default onblur is 'cancel', which fires onreset too, so the same teardown can decrement twice and
// the counter goes NEGATIVE, which is just as truthy and wedges identically.
var _reloadInFlight = false;

// Escape server-provided strings (file/folder names, device name) before they are
// concatenated into HTML, to prevent stored XSS via crafted names.
function _escapeHTML(s) {
  return String(s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

function formatFileSize(bytes) {
  if (bytes >= 1000000000) {
    return (bytes / 1000000000).toFixed(2) + ' GB';
  }
  if (bytes >= 1000000) {
    return (bytes / 1000000).toFixed(2) + ' MB';
  }
  return (bytes / 1000).toFixed(2) + ' KB';
}

function _showError(message, textStatus, errorThrown) {
  $("#alerts").prepend(tmpl("template-alert", {
    level: "danger",
    title: (errorThrown != "" ? errorThrown : textStatus) + ": ",
    description: message
  }));
}

// Whether a rename box is open is DERIVED from the DOM rather than remembered, so there is no
// pairing to get wrong and nothing to leak: if the box is destroyed by a listing, the next question
// simply answers "no". That is what makes this self-healing where the counter was not — a missed
// flush leaves a stale listing until the next reload, not a permanently frozen page.
function _editorIsOpen() {
  return $("#listing").find("form input[name=value]").length > 0;
}

function _flushPendingReloads() {
  if ((_pendingReloads.length > 0) && !_reloadInFlight && !_editorIsOpen()) {
    _reload(_pendingReloads.shift());
  }
}

function _reload(path) {
  // Coerce at the single entry point rather than at each call site: everything below
  // (and the server) treats a path as a string.
  if (!path) {
    path = "/";
  }

  _requestedPath = path;

  if (_reloadInFlight || _editorIsOpen()) {
    if ($.inArray(path, _pendingReloads) < 0) {
      _pendingReloads.push(path);
    }
    return;
  }

  _reloadInFlight = true;
  $.ajax({
    url: 'list',
    type: 'GET',
    data: {path: path},
    dataType: 'json'
  }).fail(function(jqXHR, textStatus, errorThrown) {
    _showError("Failed retrieving contents of \"" + path + "\"", textStatus, errorThrown);
  }).done(function(data, textStatus, jqXHR) {
    var scrollPosition = $(document).scrollTop();
    
    if (!_pathRendered || (path != _path)) {
      _pathRendered = true;
      $("#path").empty();
      if (path == "/") {
        $("#path").append('<li class="active">' + _escapeHTML(_device) + '</li>');
      } else {
        $("#path").append('<li data-path="/"><a>' + _escapeHTML(_device) + '</a></li>');
        var components = path.split("/").slice(1, -1);
        for (var i = 0; i < components.length - 1; ++i) {
          var subpath = "/" + components.slice(0, i + 1).join("/") + "/";
          $("#path").append('<li data-path="' + _escapeHTML(subpath) + '"><a>' + _escapeHTML(components[i]) + '</a></li>');
        }
        $("#path > li").click(function(event) {
          _reload($(this).data("path"));
          event.preventDefault();
        });
        $("#path").append('<li class="active">' + _escapeHTML(components[components.length - 1]) + '</li>');
      }
      _path = path;

      // Update URL hash to preserve path on refresh
      if (path == "/") {
        history.replaceState(null, '', window.location.pathname);
      } else {
        history.replaceState(null, '', '#' + encodeURIComponent(path));
      }
    }
    
    $("#listing").empty();
    for (var i = 0, file; file = data[i]; ++i) {
      $(tmpl("template-listing", file)).data(file).appendTo("#listing");
    }
    
    $(".edit").editable(function(value, settings) { 
      var name = $(this).parent().parent().data("name");
      // <input> in the Text state applies the "strip newlines" value sanitization algorithm, so the
      // box can never hold a CR or LF even when the real name contains one. Comparing against the
      // raw name was therefore unconditionally true for such a file, and opening the rename box and
      // pressing Enter — with nothing typed — silently renamed it on disk. Same shape as the "&"
      // seeding fix below, one layer further down: there the mangling was jeditable's and seeding
      // cured it, here it is the browser's own and no seeding can. Compare against what the box can
      // hold, so "unchanged" means unchanged.
      var comparable = String(name).replace(/[\r\n]/g, "");
      if (value != comparable) {
        var path = $(this).parent().parent().data("path");
        $.ajax({
          url: 'move',
          type: 'POST',
          data: {oldPath: path, newPath: _path + value},
          dataType: 'json'
        }).fail(function(jqXHR, textStatus, errorThrown) {
          _showError("Failed moving \"" + path + "\" to \"" + _path + value + "\"", textStatus, errorThrown);
        }).always(function() {
          _reload(_path);
        });
      }
      // jeditable puts the returned string back with .html(), so escape it — the input
      // now holds the real name, and a "<" in it would otherwise be parsed as markup.
      return _escapeHTML(value);
    }, {
      // Seed the edit box with the real name from /list. jeditable otherwise pre-fills it
      // from the element's *serialized HTML*, so "A & B.txt" arrives as "A &amp; B.txt",
      // which never equals the name compared against above: pressing Enter without typing
      // anything fired a move and renamed the file on disk to the escaped text — then to
      // "A &amp;amp; B.txt" on the next pass. Silent corruption of a common character.
      data: function(revert, settings) {
        var name = $(this).parent().parent().data("name");
        return (name === undefined || name === null) ? revert : String(name);
      },
      // Nothing to disable on edit any more — _editorIsOpen() sees the box itself. These only
      // flush, and do it after the current turn so jeditable has removed the form first; asking
      // while it is still in the DOM would answer "still editing" and skip the flush.
      onsubmit: function(settings, original) {
        setTimeout(_flushPendingReloads, 0);
      },
      onreset: function(settings, original) {
        setTimeout(_flushPendingReloads, 0);
      },
      tooltip: 'Click to rename...'
    });
    
    $(".button-download").click(function(event) {
      var path = $(this).parent().parent().data("path");
      setTimeout(function() {
        window.location = "download?path=" + encodeURIComponent(path);
      }, 0);
    });
    
    $(".button-open").click(function(event) {
      var path = $(this).parent().parent().data("path");
      _reload(path);
    });
    
    $(".button-move").click(function(event) {
      var path = $(this).parent().parent().data("path");
      if (path[path.length - 1] == "/") {
        path = path.slice(0, path.length - 1);
      }
      $("#move-input").data("path", path);
      $("#move-input").val(path);
      $("#move-modal").modal("show");
    });
    
    $(".button-delete").click(function(event) {
      var path = $(this).parent().parent().data("path");
      $.ajax({
        url: 'delete',
        type: 'POST',
        data: {path: path},
        dataType: 'json'
      }).fail(function(jqXHR, textStatus, errorThrown) {
        _showError("Failed deleting \"" + path + "\"", textStatus, errorThrown);
      }).always(function() {
        _reload(_path);
      });
    });
    
    $(document).scrollTop(scrollPosition);
  }).always(function() {
    _reloadInFlight = false;
    _flushPendingReloads();
  });
}

$(document).ready(function() {
  
  // Workaround Firefox and IE not showing file selection dialog when clicking on "upload-file" <button>
  // Making it a <div> instead also works but then it the button doesn't work anymore with tab selection or accessibility
  $("#upload-file").click(function(event) {
    $("#fileupload").click();
  });
  
  // Prevent event bubbling when using workaround above
  $("#fileupload").click(function(event) {
    event.stopPropagation();
  });
  
  $("#fileupload").fileupload({
    dropZone: $(document),
    pasteZone: null,
    autoUpload: true,
    sequentialUploads: true,
    // limitConcurrentUploads: 2,
    // forceIframeTransport: true,
    
    url: 'upload',
    type: 'POST',
    dataType: 'json',
    
    start: function(e) {
      $(".uploading").show();
    },
    
    stop: function(e) {
      $(".uploading").hide();
    },
    
    add: function(e, data) {
      var file = data.files[0];
      data.formData = {
        path: _path
      };
      data.context = $(tmpl("template-uploads", {
        path: _path + file.name
      })).appendTo("#uploads");
      var jqXHR = data.submit();
      data.context.find("button").click(function(event) {
        jqXHR.abort();
      });
    },
    
    progress: function(e, data) {
      var progress = parseInt(data.loaded / data.total * 100, 10);
      data.context.find(".progress-bar").css("width", progress + "%");
    },
    
    done: function(e, data) {
      _reload(_path);
    },
    
    fail: function(e, data) {
      var file = data.files[0];
      if (data.errorThrown != "abort") {
        _showError("Failed uploading \"" + file.name + "\" to \"" + _path + "\"", data.textStatus, data.errorThrown);
      }
    },
    
    always: function(e, data) {
      data.context.remove();
    },
    
  });
  
  $("#create-input").keypress(function(event) {
    if (event.keyCode == ENTER_KEYCODE) {
      $("#create-confirm").click();
    };
  });
  
  $("#create-modal").on("shown.bs.modal", function(event) {
    $("#create-input").focus();
    $("#create-input").select();
  });
  
  $("#create-folder").click(function(event) {
    $("#create-input").val("Untitled folder");
    $("#create-modal").modal("show");
  });
  
  $("#create-confirm").click(function(event) {
    $("#create-modal").modal("hide");
    var name = $("#create-input").val();
    if (name != "") {
      $.ajax({
        url: 'create',
        type: 'POST',
        data: {path: _path + name},
        dataType: 'json'
      }).fail(function(jqXHR, textStatus, errorThrown) {
        _showError("Failed creating folder \"" + name + "\" in \"" + _path + "\"", textStatus, errorThrown);
      }).always(function() {
        _reload(_path);
      });
    }
  });
  
  $("#move-input").keypress(function(event) {
    if (event.keyCode == ENTER_KEYCODE) {
      $("#move-confirm").click();
    };
  });
  
  $("#move-modal").on("shown.bs.modal", function(event) {
    $("#move-input").focus();
    $("#move-input").select();
  })
  
  $("#move-confirm").click(function(event) {
    $("#move-modal").modal("hide");
    var oldPath = $("#move-input").data("path");
    var newPath = $("#move-input").val();
    if ((newPath != "") && (newPath[0] == "/") && (newPath != oldPath)) {
      $.ajax({
        url: 'move',
        type: 'POST',
        data: {oldPath: oldPath, newPath: newPath},
        dataType: 'json'
      }).fail(function(jqXHR, textStatus, errorThrown) {
        _showError("Failed moving \"" + oldPath + "\" to \"" + newPath + "\"", textStatus, errorThrown);
      }).always(function() {
        _reload(_path);
      });
    }
  });
  
  $("#reload").click(function(event) {
    _reload(_path);
  });

  // Read the current path out of the URL hash, defaulting to the root. The hash is
  // whatever the user typed, so decodeURIComponent throws URIError on a malformed
  // escape such as "/#%" — uncaught here it would abort $(document).ready before the
  // first _reload(), leaving the page permanently empty.
  function _pathFromHash() {
    if (!window.location.hash) {
      return "/";
    }
    var hashPath;
    try {
      hashPath = decodeURIComponent(window.location.hash.substring(1));
    } catch (e) {
      return "/";
    }
    return (hashPath && hashPath.charAt(0) === '/') ? hashPath : "/";
  }

  // Restore path from URL hash on page load, or start at root
  _reload(_pathFromHash());

  // Handle browser back/forward navigation
  $(window).on('hashchange', function() {
    var hashPath = _pathFromHash();
    if (hashPath !== _path) {
      _reload(hashPath);
    }
  });

  // Server-Sent Events for live updates.
  //
  // ONE stream per browser, not one per tab. A browser allows six HTTP/1.1 connections per origin
  // and an EventSource never completes, so six open tabs consumed all six and the UI deadlocked in
  // every tab at once — /list, /upload, /delete, and even a seventh tab's initial document, had no
  // socket left. Measured: tabs 1-5 answered in 2 ms, the sixth timed out, a seventh rendered
  // nothing for 13 minutes. The server was idle throughout with 122 free connection slots and 10
  // free SSE channels, so kMaxSSEChannels (16) sits above the bound that actually binds: a single
  // browser deadlocks itself at 6 and can never reach 16.
  //
  // The obvious fix — close the stream while the tab is hidden — was measured and is WORSE. The
  // server only reclaims a browser-closed channel when a heartbeat write fails, 20-33 s later, so
  // ordinary tab switching leaves zombies: 25 of 40 reconnects were refused and the tab actually
  // being looked at stopped receiving updates. It also does nothing for six SIMULTANEOUSLY VISIBLE
  // tabs (split view, a tiled window manager), where nothing is ever hidden.
  //
  // So exactly one tab holds the stream and relays what it receives to the rest. Leadership is a
  // Web Lock, which the browser releases by itself when the holding tab goes away, so there is no
  // heartbeat, no timeout, and no way to end up with the stream unheld or held twice. Where either
  // API is missing, the old one-stream-per-tab behaviour stands — correct for a single tab, and no
  // worse than before for several.
  if (typeof(EventSource) !== "undefined") {
    var _eventChannel = (typeof(BroadcastChannel) !== "undefined") ? new BroadcastChannel('wsk-uploader-events') : null;

    var _applyChangeEvent = function(data) {
      var eventPath = data.path || data.oldPath || '';

      // For external changes, path is the changed directory
      // For internal changes, path is the file path - get its directory
      var eventDir;
      if (data.type === 'external') {
        eventDir = eventPath;
      } else {
        // Strip a trailing slash first: folder create/delete events carry the
        // folder's own path (e.g. "/Docs/New/"), and we want its PARENT dir so
        // clients viewing "/Docs/" reload.
        var p = eventPath.replace(/\/+$/, '');
        eventDir = p.substring(0, p.lastIndexOf('/') + 1) || '/';
      }

      // Reload only if the changed directory IS the currently-viewed directory.
      // For a move, the destination's directory may be the current path too.
      // (Compare directories, not a path prefix, so moving into a subdirectory
      // of the current folder doesn't trigger a spurious reload.)
      var newDir = null;
      if (data.newPath) {
        var np = data.newPath.replace(/\/+$/, '');
        newDir = np.substring(0, np.lastIndexOf('/') + 1) || '/';
      }
      if (eventDir === _path || newDir === _path) {
        _reload(_path);
      }
    };

    if (_eventChannel) {
      // A follower tab holds no socket of its own and learns about changes from the leader.
      _eventChannel.onmessage = function(event) {
        _applyChangeEvent(event.data);
      };
    }

    var _openEventStream = function() {
      var eventSource = new EventSource('/events');

      eventSource.addEventListener('change', function(event) {
        var data = JSON.parse(event.data);

        if (_eventChannel) {
          _eventChannel.postMessage(data);  // Relay before acting, so no tab is served later than this one.
        }

        _applyChangeEvent(data);
      });

      eventSource.onopen = function() {
        // Re-sync on every (re)connect so any change missed while disconnected is picked up
        // instead of leaving a stale listing. Against the path most recently REQUESTED, not the
        // one already rendered — on a deep link the listing has not arrived yet.
        _reload(_requestedPath);
      };

      eventSource.onerror = function() {
        console.log('SSE connection error, will auto-reconnect');
      };
    };

    if (_eventChannel && navigator.locks && navigator.locks.request) {
      // The promise never settles, so this tab holds the lock for as long as it lives. When it goes
      // away the browser releases the lock and whichever tab is next in the queue opens the stream.
      navigator.locks.request('wsk-uploader-events', function() {
        _openEventStream();
        return new Promise(function() {});
      });
    } else {
      _openEventStream();
    }
  }

});
