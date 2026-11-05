// "weberl:tick" is dispatched by the Weberl beacon for every "tick" event the
// server pushes (see clock_view:tick/1). Listening on document works whatever
// the order in which the scripts load.
document.addEventListener("weberl:tick", function (event) {
  document.getElementById("time").textContent = event.detail;
});
