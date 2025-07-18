/*
 * Copyright (C) 2011 - present Instructure, Inc.
 *
 * This file is part of Canvas.
 *
 * Canvas is free software: you can redistribute it and/or modify it under
 * the terms of the GNU Affero General Public License as published by the Free
 * Software Foundation, version 3 of the License.
 *
 * Canvas is distributed in the hope that it will be useful, but WITHOUT ANY
 * WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
 * A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
 * details.
 *
 * You should have received a copy of the GNU Affero General Public License along
 * with this program. If not, see <http://www.gnu.org/licenses/>.
 */

import $ from 'jquery'
import authenticity_token from '@canvas/authenticity-token'

if (!('INST' in window)) window.INST = {}

const DONE_READY_STATE = 4

const _getJSON = $.getJSON
$.getJSON = function (url, data, _callback) {
  const xhr = _getJSON.apply($, arguments)
  $.ajaxJSON.storeRequest(xhr, url, 'GET', data)
  return xhr
}
// Wrapper for default $.ajax behavior.  On error will call
// the default error method if no error method is provided.
$.ajaxJSON = function (url, submit_type, data = {}, success, error, options) {
  if (!url && error) {
    error(null, null, 'URL required for requests', null)
    return
  }
  url = url || '.'
  if (
    submit_type !== 'GET' &&
    // if it's a json request and has already been JSON.stringify'ed,
    //  then we can't attach properties to `data` since it's already a string
    typeof data !== 'string'
  ) {
    data._method = submit_type
    submit_type = 'POST'
    data.authenticity_token = authenticity_token()
  }

  let debugStack = undefined
  if (process.env.NODE_ENV === 'test') {
    debugStack = new Error().stack
  }

  const ajaxError = function (xhr, textStatus, errorThrown) {
    if (textStatus === 'abort') {
      return // request aborted, do nothing
    }
    let data = xhr
    if (xhr.responseText) {
      const text = xhr.responseText.replace(/(<([^>]+)>)/gi, '')
      data = {message: text}
      try {
        data = JSON.parse(xhr.responseText)
      } catch (_e) {
        // no-op
      }
    }
    if (options && options.skipDefaultError) {
      $.ajaxJSON.ignoredXHRs.push(xhr)
    }
    if (error && $.isFunction(error)) {
      if (process.env.NODE_ENV === 'test') {
        try {
          const blurb =
            'An unstubbed ajaxJSON request was made and has likely caused an unrelated test to fail. Please inspect the following stacktrace to find the offending test and either skip it and create a ticket with the appropriate team or fix it yourself. We recommend using Mock Service Worker (MSW).'
          const msg = `${blurb}\nstack: ${new Error().stack}\n*** initiator: ${debugStack}`
          if (data && !data.stack) {
            data.stack = msg
          } else {
            console.error(msg)
          }
        } catch (_e) {}
      }
      error(data, xhr, textStatus, errorThrown)
    } else {
      $.ajaxJSON.unhandledXHRs.push(xhr)
    }
  }
  const params = {
    url,
    dataType: 'json',
    type: submit_type,
    success(data, _textStatus, xhr) {
      data = data || {}
      let page_view_update_url = null
      if (
        xhr &&
        xhr.getResponseHeader &&
        (page_view_update_url = xhr.getResponseHeader('X-Canvas-Page-View-Update-Url'))
      ) {
        setTimeout(() => {
          $(document).triggerHandler('page_view_update_url_received', page_view_update_url)
        }, 50)
      }
      if (!data.length && data.errors) {
        ajaxError(data.errors, null, '')
        if (!options || !options.skipDefaultError) {
          $.fn.defaultAjaxError.func.call(
            $.fn.defaultAjaxError.object,
            null,
            data,
            '0',
            data.errors,
          )
        } else {
          $.ajaxJSON.ignoredXHRs.push(xhr)
        }
      } else if (success && $.isFunction(success)) {
        success(data, xhr)
      }
    },
    error(_xhr) {
      ajaxError.apply(this, arguments)
    },
    complete(_xhr) {},
    data,
  }
  if (options && options.timeout) {
    params.timeout = options.timeout
  }
  if (options && options.contentType) {
    params.contentType = options.contentType
  }

  const xhr = $.ajax(params)
  $.ajaxJSON.storeRequest(xhr, url, submit_type, data)
  return xhr
}
export const ajaxJSON = $.ajaxJSON
$.ajaxJSON.unhandledXHRs = []
$.ajaxJSON.ignoredXHRs = []
$.ajaxJSON.passedRequests = []
$.ajaxJSON.storeRequest = function (xhr, url, submit_type, data) {
  $.ajaxJSON.passedRequests.push({xhr, url, submit_type, data})
}

$.ajaxJSON.findRequest = xhr => $.ajaxJSON.passedRequests.find(req => req.xhr === xhr)

$.ajaxJSON.abortRequest = xhr => {
  if (xhr && xhr.readyState !== DONE_READY_STATE) {
    xhr.abort()
  }
}

$.ajaxJSON.isUnauthenticated = function (xhr) {
  if (xhr.status !== 401) {
    return false
  }

  let json_data
  try {
    json_data = JSON.parse(xhr.responseText)
  } catch (e) {
    // no-op
  }

  return !!json_data && json_data.status === 'unauthenticated'
}

// Defines a default error for all ajax requests.  Will always be called
// in the development environment, and as a last-ditch error catching
// otherwise.  See "ajax_errors.js"
$.fn.defaultAjaxError = function (func) {
  $.fn.defaultAjaxError.object = this
  $.fn.defaultAjaxError.func = function (event, request, settings, error) {
    const inProduction = INST.environment === 'production'
    const unhandled = $.inArray(request, $.ajaxJSON.unhandledXHRs) !== -1
    const ignore = $.inArray(request, $.ajaxJSON.ignoredXHRs) !== -1
    if ((!inProduction || unhandled || $.ajaxJSON.isUnauthenticated(request)) && !ignore) {
      // $.grep will throw an error if it somehow gets something without length like undefined
      $.ajaxJSON.unhandledXHRs = $.ajaxJSON.unhandledXHRs
        ? $.grep($.ajaxJSON.unhandledXHRs, xhr => xhr !== request)
        : $.ajaxJSON.unhandledXHRs
      const debugOnly = !!unhandled
      func.call(this, event, request, settings, error, debugOnly)
    }
  }
  this.ajaxError($.fn.defaultAjaxError.func)
}

export default $.ajaxJSON
