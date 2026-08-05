// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
// import {Socket} from "phoenix"
// import {LiveSocket} from "phoenix_live_view"
// import {hooks as colocatedHooks} from "phoenix-colocated/jido_assembly"
// import topbar from "../vendor/topbar"

// const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
// const liveSocket = new LiveSocket("/live", Socket, {
//   longPollFallbackMs: 2500,
//   params: {_csrf_token: csrfToken},
//   hooks: {...colocatedHooks},
// })

// Show progress bar on live navigation and form submits
// topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
// window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
// window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
// liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
// window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
// if (process.env.NODE_ENV === "development") {
//   window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
//     // Enable server log streaming to client.
//     // Disable with reloader.disableServerLogs()
//     reloader.enableServerLogs()
// 
//     // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
//     //
//     //   * click with "c" key pressed to open at caller location
//     //   * click with "d" key pressed to open at function component definition location
//     let keyDown
//     window.addEventListener("keydown", e => keyDown = e.key)
//     window.addEventListener("keyup", _e => keyDown = null)
//     window.addEventListener("click", e => {
//       if(keyDown === "c"){
//         e.preventDefault()
//         e.stopImmediatePropagation()
//         reloader.openEditorAtCaller(e.target)
//       } else if(keyDown === "d"){
//         e.preventDefault()
//         e.stopImmediatePropagation()
//         reloader.openEditorAtDef(e.target)
//       }
//     }, true)
// 
//     window.liveReloader = reloader
//   })
// }


const composerFieldSelector = "[data-assembly-composer] input[type='text'], [data-assembly-composer] textarea"
const chatScrollSelector = "[data-assembly-chat-scroll]"
const chatMessageSelector = "[data-assembly-message-id]"
const chatEndSelector = "[data-assembly-chat-end]"
const chatBottomThreshold = 160

const runAfterPaint = (callback) => {
  requestAnimationFrame(() => requestAnimationFrame(callback))
}

const chatBottomDistance = (scroller) => (
  scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight
)

const chatMessageSignature = (scroller) => {
  const messages = scroller.querySelectorAll(chatMessageSelector)
  const lastMessage = messages[messages.length - 1]
  const lastMessageId = lastMessage?.getAttribute("data-assembly-message-id") || ""

  return `${messages.length}:${lastMessageId}`
}

const scrollChatToBottom = (scroller, { behavior = "smooth", force = false } = {}) => {
  if (!scroller) return

  const shouldScroll =
    force ||
    scroller.dataset.assemblyStickToBottom !== "false" ||
    chatBottomDistance(scroller) <= chatBottomThreshold

  if (!shouldScroll) return

  runAfterPaint(() => {
    const end = scroller.querySelector(chatEndSelector)

    if (end) {
      end.scrollIntoView({ block: "end", behavior })
    } else {
      scroller.scrollTo({ top: scroller.scrollHeight, behavior })
    }
  })
}

const bindChatScroller = (scroller) => {
  if (scroller.dataset.assemblyChatScrollBound === "true") return

  scroller.dataset.assemblyChatScrollBound = "true"
  scroller.dataset.assemblyStickToBottom = "true"
  scroller.dataset.assemblyMessageSignature = chatMessageSignature(scroller)

  scroller.addEventListener("scroll", () => {
    scroller.dataset.assemblyStickToBottom =
      chatBottomDistance(scroller) <= chatBottomThreshold ? "true" : "false"
  }, { passive: true })

  const observer = new MutationObserver(() => {
    const nextSignature = chatMessageSignature(scroller)

    if (nextSignature === scroller.dataset.assemblyMessageSignature) return

    scroller.dataset.assemblyMessageSignature = nextSignature
    scrollChatToBottom(scroller, { force: true })
  })

  observer.observe(scroller, { childList: true, subtree: true })
  scrollChatToBottom(scroller, { behavior: "auto", force: true })
}

const bindChatScrollers = () => {
  document.querySelectorAll(chatScrollSelector).forEach(bindChatScroller)
}

let chatScrollObserverStarted = false

const startChatScrollObserver = () => {
  if (chatScrollObserverStarted) return

  const root = document.body || document.documentElement

  if (!root?.nodeType) return

  chatScrollObserverStarted = true

  new MutationObserver(bindChatScrollers).observe(root, {
    childList: true,
    subtree: true
  })
}

const startChatScroll = () => {
  bindChatScrollers()
  startChatScrollObserver()
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", startChatScroll, { once: true })
} else {
  startChatScroll()
}

const pageWindow = document.defaultView || globalThis

pageWindow.AssemblyChat = {
  scrollToBottom: () => {
    document.querySelectorAll(chatScrollSelector).forEach((scroller) => {
      scrollChatToBottom(scroller, { force: true })
    })
  }
}

document.addEventListener("keydown", (event) => {
  const field = event.target.closest?.(composerFieldSelector)

  if (!field) return
  if (event.key !== "Enter") return
  if (event.shiftKey || event.altKey || event.ctrlKey || event.metaKey || event.isComposing) return

  event.preventDefault()
  field.form?.requestSubmit()
}, true)

// Handle flash close
document.querySelectorAll("[role=alert][data-flash]").forEach((el) => {
  el.addEventListener("click", () => {
    el.setAttribute("hidden", "")
  })
})
