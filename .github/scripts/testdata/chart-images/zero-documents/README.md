# zero-documents

Its only template sits behind {{- if .Values.enabled }}, which defaults to false. Expect the zero-document ::warning:: (with the .helmignore sentence) and a passing gate.

These charts are the ONLY coverage the chart-images gate's cannot-render notice and zero-document
warning will ever have. A healthy repository never reaches either message, so no real caller can
exercise them. Do not delete these directories as unused test charts: without them those messages go
back to being unproven. They are read by .github/scripts/chart_images_test.py.
