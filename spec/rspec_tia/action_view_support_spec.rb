require 'active_support'
require 'active_support/notifications'
require 'rspec_tia/action_view_support'
require 'rspec_tia/rails_support'

RSpec.describe RspecTia::ActionViewSupport do
  def notify(identifier, event: 'render_partial.action_view', **payload)
    ActiveSupport::Notifications.instrument(event, payload.merge(identifier: identifier)) {}
  end

  it 'keeps real project files, normalizes paths, and ignores virtual, missing and external identifiers' do
    with_project(['app/views/_item.html.erb', 'app/views/_layout.html.erb']) do |root|
      collector = described_class.new(root: root).subscribe
      begin
        path = File.join(root, 'app/views/_item.html.erb')
        notify(File.join(root, 'app/views/../views/_item.html.erb'))
        notify(path)
        notify(nil, layout: File.join(root, 'app/views/_layout.html.erb'))
        [nil, '', 'inline template', 'app/views/_item.html.erb', "#{root}/missing.erb",
         "#{root}/bad\0.erb", __FILE__, 42].each { |identifier| notify(identifier) }
        File.symlink(__FILE__, File.join(root, 'app/views/_external.html.erb'))
        notify(File.join(root, 'app/views/_external.html.erb'))
        expect(collector.flush).to eq(['app/views/_item.html.erb'])
        expect(collector.flush).to be_empty
      ensure
        collector.unsubscribe
      end
    end
  end

  it 'records repeated renders after flush, subscribes once, and can unsubscribe and restart' do
    with_project(['app/views/item.html.erb']) do |root|
      collector = described_class.new(root: root)
      begin
        2.times { collector.subscribe }
        path = File.join(root, 'app/views/item.html.erb')
        described_class::EVENTS.each do |event|
          notify(path, event: event)
          expect(collector.flush).to eq(['app/views/item.html.erb'])
        end
        collector.unsubscribe
        notify(path)
        expect(collector.flush).to be_empty
        collector.subscribe
        notify(path)
        expect(collector.flush).to eq(['app/views/item.html.erb'])
      ensure
        collector.unsubscribe
      end
    end
  end

  [RspecTia::ActionViewSupport, RspecTia::RailsSupport].each do |collector_class|
    it "does not leak or duplicate #{collector_class} notification subscriptions" do
      collector = collector_class.new(root: Dir.pwd)
      tokens = []
      allow(ActiveSupport::Notifications).to receive(:unsubscribe).and_call_original
      allow(ActiveSupport::Notifications).to receive(:subscribe).and_wrap_original do |original, *args, &block|
        original.call(*args, &block).tap { |token| tokens << token }
      end
      begin
        collector.subscribe
        count = tokens.size
        expect(count).to be_positive
        collector.subscribe
        expect(tokens.size).to eq(count)
        tokens.each { |token| expect(ActiveSupport::Notifications).to receive(:unsubscribe).with(token).and_call_original }
        collector.unsubscribe
        collector.unsubscribe
        collector.subscribe
        expect(tokens.size).to eq(count * 2)
      ensure
        collector.unsubscribe
      end
    end
  end
end
