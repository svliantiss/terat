// terat-trace.js - pass one trace id from terat through pi to the router.
//
// pi does not propagate W3C trace context, so a question, the model calls it
// causes and the router's own ledger are otherwise three unrelated records.
// This brings them together: terat mints an id, exports it, and this puts it on
// the request as `traceparent`, which router (Manifest) reads back out as
// `requests.trace_id`. One id then finds the work in both places.
//
// Loaded with `pi -e`, which is per run, so it only exists when terat asks for
// it. With the variables unset it returns immediately and changes nothing:
// pi's own header resolution treats an empty value as a fatal error, so the
// "do nothing at all" path here is what keeps a bare `pi` working.
export default function (pi) {
	const id = process.env.TERAT_TRACE_ID;
	const span = process.env.TERAT_TRACE_SPAN;
	if (!id || !span) return;
	pi.registerProvider(process.env.TERAT_TRACE_PROVIDER || "router", {
		headers: { traceparent: `00-${id}-${span}-01` },
	});
}
