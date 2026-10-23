RSpec.describe 'context hooks' do
  before(:context) { @before_value = ContextBefore.call }
  after(:context) { expect(ContextAfter.call).to eq('context after') }

  it('uses before context') { expect(@before_value).to eq('context before') }

  context 'nested context' do
    before(:context) { @nested_value = NestedBefore.call }
    after(:context) { expect(NestedAfter.call).to eq('nested after') }
    it('uses nested before context') { expect(@nested_value).to eq('nested before') }
  end

  context 'all aliases' do
    before(:all) { @all_value = AllBefore.call }
    after(:all) { expect(AllAfter.call).to eq('all after') }
    it('uses before all') { expect(@all_value).to eq('all before') }
  end
end

RSpec.describe 'another top-level group in the same file' do
  before(:context) { @value = SecondGroupValue.call }
  it('retains the second group dependency') { expect(@value).to eq('second group') }
end
