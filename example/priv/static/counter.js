// The button sends a request to counter_view:handle_request/3. The new count
// is not written here: the server re-renders the "count" region and the Weberl
// beacon swaps it in. The reply is only used for the log line below.
document.getElementById("add").addEventListener("click", function () {
  Weberl.request("add", 1).then(function (count) {
    console.log("server count:", count);
  });
});

// "weberl:region" is dispatched on document after a region was swapped in.
document.addEventListener("weberl:region", function (event) {
  console.log("region updated:", event.detail.region);
});

// A request answered from the page's private view data, every two seconds.
setInterval(function () {
  if (window.Weberl) {
    Weberl.request("age", null).then(function (seconds) {
      document.getElementById("age").textContent = seconds;
    });
  }
}, 2000);
