// The button asks the server to rename; the server re-renders the regions that use the name
// (which ones depends on the layout the page was rendered with) and the beacon swaps them in.
document.getElementById("rename").addEventListener("click", function () {
  Weberl.request("rename", "zed");
});
