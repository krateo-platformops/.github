# required-with-ci

The same chart with ci/render-values.yaml setting x. Expect a clean render: no error, no notice, no warning, and at least one document.

These charts are the ONLY coverage the chart-images gate's cannot-render notice and zero-document
warning will ever have. A healthy repository never reaches either message, so no real caller can
exercise them. Do not delete these directories as unused test charts: without them those messages go
back to being unproven. They are read by .github/scripts/chart_images_test.py.
